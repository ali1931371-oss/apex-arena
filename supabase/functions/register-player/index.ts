import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SECRET_KEYS_RAW = Deno.env.get("SUPABASE_SECRET_KEYS") ?? "";
const ALLOWED_ORIGINS = (Deno.env.get("ALLOWED_ORIGINS") ?? "").split(",").map(v => v.trim()).filter(Boolean);
const TURNSTILE_SECRET = Deno.env.get("TURNSTILE_SECRET") ?? "";
const MAX_BODY_SIZE = 10 * 1024;

function jsonResponse(status: number, data: Record<string, unknown>, origin?: string) {
  const headers = new Headers({"Content-Type":"application/json; charset=utf-8","Cache-Control":"no-store","Vary":"Origin"});
  if (origin && ALLOWED_ORIGINS.includes(origin)) {
    headers.set("Access-Control-Allow-Origin", origin);
    headers.set("Access-Control-Allow-Headers","authorization, x-client-info, apikey, content-type");
    headers.set("Access-Control-Allow-Methods","POST, OPTIONS");
  }
  return new Response(JSON.stringify(data), {status,headers});
}
function cleanText(value: unknown, maxLength: number): string {
  if (typeof value !== "string") return "";
  return value.trim().replace(/[\u0000-\u001F\u007F]/g,"").slice(0,maxLength);
}
function validUsername(value: string): boolean { return /^[a-z0-9][a-z0-9._-]{2,29}$/.test(value); }
function validPhone(value: string): boolean { return /^\+?[0-9]{7,15}$/.test(value); }
function validUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}
async function readLimitedBody(req: Request): Promise<string | null> {
  const reader=req.body?.getReader(); if(!reader) return null;
  const chunks:Uint8Array[]=[]; let total=0;
  while(true){const {done,value}=await reader.read();if(done)break;total+=value.length;if(total>MAX_BODY_SIZE){await reader.cancel();return null;}chunks.push(value);}
  const result=new Uint8Array(total);let offset=0;
  for(const chunk of chunks){result.set(chunk,offset);offset+=chunk.length;}
  return new TextDecoder().decode(result);
}
async function verifyCaptcha(token:string,ip:string):Promise<boolean>{
  if(!TURNSTILE_SECRET)return true;
  if(!token)return false;
  const form=new URLSearchParams();form.set("secret",TURNSTILE_SECRET);form.set("response",token);if(ip)form.set("remoteip",ip);
  try{const result=await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify",{method:"POST",body:form});if(!result.ok)return false;const data=await result.json();return data.success===true;}catch{return false;}
}

Deno.serve(async (req:Request)=>{
  const origin=req.headers.get("origin")??undefined;
  if(req.method==="OPTIONS"){
    if(!origin||!ALLOWED_ORIGINS.includes(origin))return new Response(null,{status:403});
    return new Response(null,{status:204,headers:{
      "Access-Control-Allow-Origin":origin,
      "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type",
      "Access-Control-Allow-Methods":"POST, OPTIONS","Access-Control-Max-Age":"86400","Vary":"Origin"
    }});
  }
  if(origin&&!ALLOWED_ORIGINS.includes(origin))return jsonResponse(403,{error:"دامنه درخواست مجاز نیست"},origin);
  if(req.method!=="POST")return jsonResponse(405,{error:"فقط درخواست POST مجاز است"},origin);
  if(!(req.headers.get("content-type")??"").toLowerCase().includes("application/json"))return jsonResponse(415,{error:"درخواست باید JSON باشد"},origin);
  const contentLength=Number(req.headers.get("content-length")??"0");
  if(contentLength>MAX_BODY_SIZE)return jsonResponse(413,{error:"حجم اطلاعات بیش از حد مجاز است"},origin);

  try{
    const rawBody=await readLimitedBody(req);
    if(rawBody===null)return jsonResponse(413,{error:"حجم اطلاعات بیش از ۱۰ کیلوبایت است"},origin);
    let body:Record<string,unknown>;
    try{body=JSON.parse(rawBody);}catch{return jsonResponse(400,{error:"اطلاعات ارسالی معتبر نیست"},origin);}
    if(!body||typeof body!=="object"||Array.isArray(body))return jsonResponse(400,{error:"ساختار درخواست معتبر نیست"},origin);

    const fullName=cleanText(body.full_name,100);
    const audioPlayerId=cleanText(body.audio_player_id,100);
    const phone=cleanText(body.phone,25).replace(/[\s()-]/g,"");
    const username=cleanText(body.username,30).toLowerCase();
    const tournamentId=cleanText(body.tournament_id,36);
    const accountMode=cleanText(body.account_mode,10);
    const password=typeof body.password==="string"?body.password:"";
    const captchaToken=cleanText(body.captcha_token,4000);
    if(fullName.length<3)return jsonResponse(400,{error:"نام و نام خانوادگی را کامل وارد کنید"},origin);
    if(audioPlayerId.length<2)return jsonResponse(400,{error:"آیدی بازیکن معتبر نیست"},origin);
    if(!validPhone(phone))return jsonResponse(400,{error:"شماره تماس معتبر نیست"},origin);
    if(!validUsername(username))return jsonResponse(400,{error:"نام کاربری معتبر نیست"},origin);
    if(!validUUID(tournamentId))return jsonResponse(400,{error:"شناسه تورنمنت معتبر نیست"},origin);
    if(accountMode!=="new"&&accountMode!=="existing")return jsonResponse(400,{error:"نوع حساب معتبر نیست"},origin);
    if(accountMode==="new"&&(password.length<12||password.length>128))return jsonResponse(400,{error:"رمز عبور باید حداقل ۱۲ و حداکثر ۱۲۸ نویسه باشد"},origin);
    const ip=req.headers.get("cf-connecting-ip")??"";
    if(!(await verifyCaptcha(captchaToken,ip)))return jsonResponse(400,{error:"تأیید امنیتی ناموفق بود"},origin);

    if(!SUPABASE_URL||!SECRET_KEYS_RAW)throw new Error("Server configuration is missing");
    let secretKeys:Record<string,string>;
    try{secretKeys=JSON.parse(SECRET_KEYS_RAW);}catch{throw new Error("Secret configuration is invalid");}
    const secretKey=secretKeys["default"];
    if(!secretKey)throw new Error("Default server key is missing");
    const supabase=createClient(SUPABASE_URL,secretKey,{auth:{autoRefreshToken:false,persistSession:false}});

    const {data:tournament,error:tournamentError}=await supabase.from("tournaments").select("id,status").eq("id",tournamentId).maybeSingle();
    if(tournamentError)throw tournamentError;
    if(!tournament||tournament.status!=="registration")return jsonResponse(400,{error:"ثبت‌نام این تورنمنت فعال نیست"},origin);
    const {data:settings,error:settingsError}=await supabase.from("tournament_registration_settings").select("registration_open").eq("tournament_id",tournamentId).maybeSingle();
    if(settingsError)throw settingsError;
    if(!settings||settings.registration_open!==true)return jsonResponse(400,{error:"ثبت‌نام این تورنمنت بسته است"},origin);

    let userId:string;
    if(accountMode==="existing"){
      const authorization=req.headers.get("authorization")??"";
      const token=authorization.startsWith("Bearer ")?authorization.slice(7):"";
      if(!token)return jsonResponse(401,{error:"برای استفاده از حساب قبلی ابتدا وارد شوید"},origin);
      const {data:userData,error:userError}=await supabase.auth.getUser(token);
      if(userError||!userData.user)return jsonResponse(401,{error:"نشست ورود معتبر نیست؛ دوباره وارد شوید"},origin);
      userId=userData.user.id;
      const {data:profile,error:profileError}=await supabase.from("profiles").select("id,username").eq("id",userId).maybeSingle();
      if(profileError)throw profileError;
      if(!profile||String(profile.username??"").toLowerCase()!==username)return jsonResponse(403,{error:"نام کاربری با حساب واردشده مطابقت ندارد"},origin);
    }else{
      const {data:existingProfiles,error:profileError}=await supabase.from("profiles").select("id").ilike("username",username).limit(1);
      if(profileError)throw profileError;
      if(existingProfiles&&existingProfiles.length>0)return jsonResponse(409,{error:"این نام کاربری قبلاً استفاده شده است؛ گزینه بازیکن دارای حساب را انتخاب کنید"},origin);
      const internalEmail=`${username}@users.apexarena.invalid`;
      const {data:authData,error:authError}=await supabase.auth.admin.createUser({email:internalEmail,password,email_confirm:true});
      if(authError||!authData.user)return jsonResponse(409,{error:"ساخت حساب انجام نشد؛ نام کاربری را بررسی کنید"},origin);
      userId=authData.user.id;
    }

    const {data:existingRequest,error:requestCheckError}=await supabase.from("tournament_registration_requests")
      .select("id,status").eq("tournament_id",tournamentId).eq("user_id",userId).limit(1).maybeSingle();
    if(requestCheckError)throw requestCheckError;
    if(existingRequest){
      if(["cancelled","rejected"].includes(existingRequest.status)&&accountMode==="existing"){
        const {error:reopenError}=await supabase.from("tournament_registration_requests")
          .update({
            requested_display_name:fullName,status:"pending",reviewed_by:null,review_note:null,reviewed_at:null,
            created_at:new Date().toISOString(),full_name:fullName,audio_player_id:audioPlayerId,phone,username
          })
          .eq("id",existingRequest.id).eq("status",existingRequest.status);
        if(reopenError)throw reopenError;
        return jsonResponse(201,{ok:true,status:"pending",message:"درخواست قبلی شما دوباره برای بررسی ارسال شد"},origin);
      }
      if(accountMode==="new")await supabase.auth.admin.deleteUser(userId);
      return jsonResponse(409,{error:"برای این تورنمنت قبلاً درخواست ثبت‌نام ارسال کرده‌اید یا درخواست شما در حال بررسی است"},origin);
    }

    const {error:insertError}=await supabase.from("tournament_registration_requests").insert({
      tournament_id:tournamentId,user_id:userId,requested_display_name:fullName,status:"pending",
      full_name:fullName,audio_player_id:audioPlayerId,phone,username
    });
    if(insertError){
      if(accountMode==="new")await supabase.auth.admin.deleteUser(userId);
      if(insertError.code==="23505")return jsonResponse(409,{error:"درخواست ثبت‌نام تکراری است"},origin);
      throw insertError;
    }
    return jsonResponse(201,{ok:true,status:"pending",message:"درخواست ثبت‌نام شما ارسال شد و منتظر تأیید مدیر است"},origin);
  }catch(error){
    console.error("register-player error:",error);
    return jsonResponse(500,{error:"در ثبت‌نام خطایی رخ داد. لطفاً بعداً دوباره تلاش کنید"},origin);
  }
});
