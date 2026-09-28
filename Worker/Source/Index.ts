/**
 * bloxdrive-registry
 *
 * Cloudflare Worker that serves as a package registry for
 * bloxdrive. Stores package data in D1 (SQLite at the
 * edge) and exposes a simple REST API for fetching and publishing.
 *
 * Write operations (PUT, DELETE) require a bearer token that belongs
 * to a whitelisted user. Tokens are minted through the admin routes
 * and only their SHA-256 hash is stored, so the raw token is shown
 * exactly once when it is created.
 *
 * Routes:
 *   GET    /health
 *   GET    /packages/:id
 *   GET    /packages/:id/versions/:version
 *   PUT    /packages/:id/versions/:version   (whitelisted token)
 *   DELETE /packages/:id                      (whitelisted token)
 *   GET    /admin/whitelist                   (admin token)
 *   POST   /admin/whitelist                   (admin token)
 *   DELETE /admin/whitelist/:userId           (admin token)
 */

interface Env {
    DB: D1Database;
    ADMIN_TOKEN: string;
}

type RouteMatch =
    | { route: "health" }
    | { route: "package"; packageId: string }
    | { route: "version"; packageId: string; version: string }
    | { route: "deletePackage"; packageId: string }
    | { route: "whitelist" }
    | { route: "whitelistUser"; userId: string }
    | null;

function matchRoute(method: string, pathname: string): RouteMatch {
    if (pathname === "/health") {
        return { route: "health" };
    }

    if (pathname === "/admin/whitelist") {
        return { route: "whitelist" };
    }

    const whitelistUserMatch = pathname.match(
        /^\/admin\/whitelist\/([^/]+)$/,
    );
    if (whitelistUserMatch) {
        return { route: "whitelistUser", userId: whitelistUserMatch[1] };
    }

    const versionMatch = pathname.match(
        /^\/packages\/([^/]+)\/versions\/(\d+)$/,
    );
    if (versionMatch) {
        return {
            route: "version",
            packageId: versionMatch[1],
            version: versionMatch[2],
        };
    }

    const packageMatch = pathname.match(/^\/packages\/([^/]+)$/);
    if (packageMatch) {
        if (method === "DELETE") {
            return { route: "deletePackage", packageId: packageMatch[1] };
        }
        return { route: "package", packageId: packageMatch[1] };
    }

    return null;
}

function bearerToken(request: Request): string | null {
    const header = request.headers.get("Authorization");
    if (!header || !header.startsWith("Bearer ")) {
        return null;
    }
    return header.slice("Bearer ".length);
}

function isAdmin(request: Request, env: Env): boolean {
    return bearerToken(request) === env.ADMIN_TOKEN;
}

async function hashToken(token: string): Promise<string> {
    const data = new TextEncoder().encode(token);
    const digest = await crypto.subtle.digest("SHA-256", data);
    return [...new Uint8Array(digest)]
        .map((byte) => byte.toString(16).padStart(2, "0"))
        .join("");
}

function generateToken(): string {
    const bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    let binary = "";
    for (const byte of bytes) {
        binary += String.fromCharCode(byte);
    }
    return btoa(binary)
        .replace(/\+/g, "-")
        .replace(/\//g, "_")
        .replace(/=+$/, "");
}

// Resolves the whitelisted user id for a write request, or null when
// the presented token is missing or not whitelisted.
async function authorizeWrite(
    request: Request,
    env: Env,
): Promise<string | null> {
    const token = bearerToken(request);
    if (token === null) {
        return null;
    }

    const row = await env.DB.prepare(
        "SELECT user_id FROM whitelist WHERE token_hash = ?",
    )
        .bind(await hashToken(token))
        .first<{ user_id: string }>();

    return row ? row.user_id : null;
}

function json(data: unknown, status = 200): Response {
    return new Response(JSON.stringify(data), {
        status,
        headers: { "Content-Type": "application/json" },
    });
}

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        const url = new URL(request.url);
        const method = request.method;
        const match = matchRoute(method, url.pathname);

        if (!match) {
            return json({ error: "Not found" }, 404);
        }

        if (match.route === "health") {
            return json({ status: "ok" });
        }

        if (match.route === "whitelist" || match.route === "whitelistUser") {
            if (!isAdmin(request, env)) {
                return json({ error: "Unauthorized" }, 401);
            }
            return handleAdmin(request, env, match);
        }

        // Write operations require a whitelisted token
        if (method === "PUT" || method === "DELETE") {
            const userId = await authorizeWrite(request, env);
            if (userId === null) {
                return json({ error: "Unauthorized" }, 401);
            }
            console.log(`${method} ${url.pathname} by user ${userId}`);
        }

        switch (match.route) {
            case "package":
                return handlePackage(request, env, match.packageId);
            case "version":
                return handleVersion(
                    request,
                    env,
                    match.packageId,
                    match.version,
                );
            case "deletePackage":
                return handleDeletePackage(env, match.packageId);
        }
    },
} satisfies ExportedHandler<Env>;

async function handleAdmin(
    request: Request,
    env: Env,
    match: { route: "whitelist" } | { route: "whitelistUser"; userId: string },
): Promise<Response> {
    if (match.route === "whitelist") {
        if (request.method === "GET") {
            return handleListWhitelist(env);
        }
        if (request.method === "POST") {
            return handleAddWhitelist(request, env);
        }
        return json({ error: "Method not allowed" }, 405);
    }

    if (request.method === "DELETE") {
        return handleRemoveWhitelist(env, match.userId);
    }
    return json({ error: "Method not allowed" }, 405);
}

async function handleListWhitelist(env: Env): Promise<Response> {
    const result = await env.DB.prepare(
        "SELECT user_id AS userId, name, created_at AS createdAt FROM whitelist ORDER BY created_at",
    ).all<{ userId: string; name: string; createdAt: string }>();

    return json({ entries: result.results });
}

async function handleAddWhitelist(
    request: Request,
    env: Env,
): Promise<Response> {
    let body: unknown;
    try {
        body = await request.json();
    } catch {
        return json({ error: "Invalid JSON body" }, 400);
    }

    if (typeof body !== "object" || body === null) {
        return json({ error: "A JSON object body is required" }, 400);
    }

    const { userId, name } = body as { userId?: unknown; name?: unknown };
    if (typeof userId !== "string" || userId === "") {
        return json({ error: "A non-empty userId is required" }, 400);
    }
    if (typeof name !== "string" || name === "") {
        return json({ error: "A non-empty name is required" }, 400);
    }

    const token = generateToken();
    await env.DB.prepare(
        "INSERT INTO whitelist (user_id, name, token_hash) VALUES (?, ?, ?) ON CONFLICT(user_id) DO UPDATE SET name = excluded.name, token_hash = excluded.token_hash, created_at = datetime('now')",
    )
        .bind(userId, name, await hashToken(token))
        .run();

    // The raw token is returned exactly once; only its hash is stored.
    return json({ userId, name, token });
}

async function handleRemoveWhitelist(
    env: Env,
    userId: string,
): Promise<Response> {
    const result = await env.DB.prepare(
        "DELETE FROM whitelist WHERE user_id = ?",
    )
        .bind(userId)
        .run();

    if (result.meta.changes === 0) {
        return json({ error: "User not found" }, 404);
    }

    return json({ ok: true });
}

async function handlePackage(
    request: Request,
    env: Env,
    packageId: string,
): Promise<Response> {
    if (request.method !== "GET") {
        return json({ error: "Method not allowed" }, 405);
    }

    const row = await env.DB.prepare(
        "SELECT name, (SELECT MAX(version) FROM versions WHERE package_id = ?) AS latestVersion FROM packages WHERE id = ?",
    )
        .bind(packageId, packageId)
        .first<{ name: string; latestVersion: number }>();

    if (!row) {
        return json({ error: "Package not found" }, 404);
    }

    return json({
        name: row.name,
        latestVersion: row.latestVersion ?? 0,
    });
}

async function handleVersion(
    request: Request,
    env: Env,
    packageId: string,
    versionStr: string,
): Promise<Response> {
    const version = parseInt(versionStr, 10);

    if (request.method !== "GET" && request.method !== "PUT") {
        return json({ error: "Method not allowed" }, 405);
    }

    if (request.method === "GET") {
        const row = await env.DB.prepare(
            "SELECT tree FROM versions WHERE package_id = ? AND version = ?",
        )
            .bind(packageId, version)
            .first<{ tree: string }>();

        if (!row) {
            return json({ error: "Version not found" }, 404);
        }

        return new Response(row.tree, {
            headers: { "Content-Type": "application/json" },
        });
    }

    // PUT — publish a new version. Uses a transaction to upsert the
    // package and insert the version atomically.
    const tree = await request.text();

    // Parse the tree to extract the package name if present in the
    // request, otherwise use the package ID
    let name = packageId;
    const nameHeader = request.headers.get("X-Package-Name");
    if (nameHeader) {
        name = nameHeader;
    }

    const batch = [
        env.DB.prepare(
            "INSERT INTO packages (id, name) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name",
        ).bind(packageId, name),
        env.DB.prepare(
            "INSERT INTO versions (package_id, version, tree) VALUES (?, ?, ?)",
        ).bind(packageId, version, tree),
    ];

    try {
        await env.DB.batch(batch);
    } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        if (msg.includes("UNIQUE constraint failed")) {
            return json({ error: "Version already exists" }, 409);
        }
        throw e;
    }

    return json({ ok: true });
}

async function handleDeletePackage(
    env: Env,
    packageId: string,
): Promise<Response> {
    const batch = [
        env.DB.prepare("DELETE FROM versions WHERE package_id = ?").bind(
            packageId,
        ),
        env.DB.prepare("DELETE FROM packages WHERE id = ?").bind(packageId),
    ];

    await env.DB.batch(batch);

    return json({ ok: true });
}
