const SUPABASE_ORIGIN = "https://vzythswxlvubytzmvhep.supabase.co";
const SUPABASE_SDK_URL = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2";

export default {
  async fetch(request, env) {
    const incoming = new URL(request.url);
    if (incoming.pathname.startsWith("/_supabase/")) {
      const upstreamUrl = new URL(incoming.pathname.slice("/_supabase".length) + incoming.search, SUPABASE_ORIGIN);
      const headers = new Headers(request.headers);
      headers.delete("host");
      const upstreamRequest = new Request(upstreamUrl.toString(), {
        method: request.method,
        headers,
        body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body,
        redirect: "manual"
      });
      try {
        return await fetch(upstreamRequest);
      } catch (_error) {
        return new Response(JSON.stringify({error:"upstream_unavailable",message:"ارتباط با سرویس داده در حال حاضر برقرار نشد."}), {
          status:502,
          headers:{"content-type":"application/json; charset=utf-8","cache-control":"no-store","access-control-allow-origin":incoming.origin,"vary":"Origin"}
        });
      }
    }
    if (incoming.pathname === "/_vendor/supabase-js.js") {
      if (request.method !== "GET" && request.method !== "HEAD") return new Response("Method Not Allowed",{status:405});
      try {
        const upstream = await fetch(SUPABASE_SDK_URL,{headers:{"user-agent":"APEX-ARENA-Asset-Proxy"},cf:{cacheTtl:3600,cacheEverything:true}});
        if (!upstream.ok) return new Response("SDK temporarily unavailable",{status:502});
        const responseHeaders = new Headers(upstream.headers);
        responseHeaders.set("content-type","application/javascript; charset=utf-8");
        responseHeaders.set("cache-control","public, max-age=3600, s-maxage=86400");
        responseHeaders.delete("content-encoding");
        responseHeaders.delete("content-length");
        return new Response(request.method === "HEAD" ? null : upstream.body,{status:200,headers:responseHeaders});
      } catch (_error) { return new Response("SDK temporarily unavailable",{status:502}); }
    }
    return env.ASSETS.fetch(request);
  }
};
