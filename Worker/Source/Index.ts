/**
 * bloxdrive-registry
 *
 * Cloudflare Worker that serves as a package registry for
 * bloxdrive. Stores package data in D1 (SQLite at the
 * edge) and exposes a simple REST API for fetching and publishing.
 *
 * Routes:
 *   GET    /health
 *   GET    /packages/:id
 *   GET    /packages/:id/versions/:version
 *   PUT    /packages/:id/versions/:version
 *   DELETE /packages/:id
 */

interface Env {
    DB: D1Database;
    REGISTRY_AUTH_TOKEN: string;
}

type RouteMatch =
    | { route: "health" }
    | { route: "package"; packageId: string }
    | { route: "version"; packageId: string; version: string }
    | { route: "deletePackage"; packageId: string }
    | null;

function matchRoute(method: string, pathname: string): RouteMatch {
    if (pathname === "/health") {
        return { route: "health" };
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

function isAuthorized(request: Request, env: Env): boolean {
    const header = request.headers.get("Authorization");
    return header === `Bearer ${env.REGISTRY_AUTH_TOKEN}`;
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

        // Write operations require auth
        if (method === "PUT" || method === "DELETE") {
            if (!isAuthorized(request, env)) {
                return json({ error: "Unauthorized" }, 401);
            }
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
            return json(
                { error: "Version already exists" },
                409,
            );
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
