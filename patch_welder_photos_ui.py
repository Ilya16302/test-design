from pathlib import Path

path = Path('/var/www/statv2/index_v2.html')
text = path.read_text(encoding='utf-8')

if '/* WELDER PHOTOS UI START */' in text:
    raise SystemExit('already patched')

def replace_one(old,new,name):
    global text
    c=text.count(old)
    if c!=1:
        raise SystemExit(f'{name}: count {c}')
    text=text.replace(old,new,1)
    print('OK',name)

# CSS
css = r'''
/* WELDER PHOTOS UI START */

.welder-photo-img{
  width:100%;
  height:100%;
  display:block;
  object-fit:cover;
}

.welder-photo-spinner{
  width:22px;
  height:22px;
  border:3px solid rgba(255,255,255,.20);
  border-top-color:var(--cyan);
  border-radius:50%;
  animation:welder-photo-spin .75s linear infinite;
}

@keyframes welder-photo-spin{
  to{transform:rotate(360deg)}
}

.account-menu-btn{
  overflow:visible;
}

.account-menu-btn .welder-photo-img{
  position:absolute;
  inset:0;
  border-radius:50%;
}

.account-menu-btn .welder-photo-spinner{
  position:absolute;
  left:50%;
  top:50%;
  width:19px;
  height:19px;
  margin:-9.5px 0 0 -9.5px;
  z-index:2;
}

.account-menu-avatar{
  position:relative;
  overflow:hidden;
  padding:0!important;
  min-height:44px!important;
  box-shadow:none!important;
  cursor:default;
}

.account-menu-avatar.welder-photo-ready{
  cursor:pointer;
}

.account-menu-avatar .welder-photo-img{
  position:absolute;
  inset:0;
}

.account-menu-avatar .welder-photo-spinner{
  position:absolute;
  left:50%;
  top:50%;
  margin:-11px 0 0 -11px;
}

.hero-welder-photo{
  position:relative;
  width:96px;
  height:96px;
  flex:0 0 96px;
  min-height:96px;
  padding:0;
  display:grid;
  place-items:center;
  overflow:hidden;
  border-radius:18px;
  color:#dff4ff;
  background:linear-gradient(145deg,rgba(106,179,255,.20),rgba(34,211,238,.08));
  border:1px solid rgba(106,179,255,.32);
  box-shadow:inset 0 1px 0 rgba(255,255,255,.12),0 12px 30px rgba(0,0,0,.25);
}

.hero-welder-photo.welder-photo-ready{
  cursor:pointer;
}

.hero-welder-photo svg{
  width:38px;
  height:38px;
  fill:currentColor;
}

.hero-welder-photo .welder-photo-img{
  position:absolute;
  inset:0;
}

.hero-content{
  flex:1 1 auto;
  min-width:0;
}

.welder-photo-modal-backdrop{
  position:fixed;
  inset:0;
  z-index:100000;
  display:flex;
  align-items:center;
  justify-content:center;
  padding:20px;
  background:rgba(0,0,0,.84);
  backdrop-filter:blur(12px);
}

.welder-photo-modal{
  position:relative;
  width:min(920px,96vw);
  max-height:94vh;
  display:flex;
  flex-direction:column;
  gap:12px;
  padding:16px;
  border-radius:22px;
  background:#08111f;
  border:1px solid rgba(255,255,255,.14);
  box-shadow:0 30px 100px rgba(0,0,0,.72);
}

.welder-photo-modal-image-wrap{
  min-height:220px;
  display:flex;
  align-items:center;
  justify-content:center;
  overflow:hidden;
  border-radius:16px;
  background:#02050a;
}

.welder-photo-modal-image{
  display:block;
  max-width:90vw;
  max-height:78vh;
  width:auto;
  height:auto;
  object-fit:contain;
}

.welder-photo-modal-actions{
  display:flex;
  justify-content:center;
}

.welder-photo-modal-actions button{
  min-width:150px;
}

@media(max-width:820px){
  .hero-welder-photo{
    width:76px;
    height:76px;
    min-height:76px;
    flex-basis:76px;
    border-radius:16px;
  }

  .welder-photo-modal-backdrop{
    padding:10px;
  }

  .welder-photo-modal{
    width:100%;
    max-height:96vh;
    padding:10px;
    border-radius:18px;
  }

  .welder-photo-modal-image{
    max-width:calc(100vw - 40px);
    max-height:80vh;
  }
}

/* WELDER PHOTOS UI END */
'''
pos=text.rfind('</style>')
if pos<0: raise SystemExit('no style close')
text=text[:pos]+'\n'+css+'\n'+text[pos:]
print('OK css')

# account button
old='''<div id="accountMenu" class="account-menu hidden">
  <button
    id="accountMenuBtn"
    class="account-menu-btn"
    type="button"
    aria-label="Открыть личный кабинет"
    aria-haspopup="true"
    aria-expanded="false"
  >
    <svg
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path
        d="M12 12.2a4.35 4.35 0 1 0 0-8.7
           4.35 4.35 0 0 0 0 8.7Zm0 2.1
           c-4.35 0-7.9 2.5-7.9 5.55
           0 .36.29.65.65.65h14.5
           c.36 0 .65-.29.65-.65
           0-3.05-3.55-5.55-7.9-5.55Z"
      />
    </svg>

    <span class="account-menu-online"></span>
  </button>'''
new='''<div id="accountMenu" class="account-menu hidden">
  <button
    id="accountMenuBtn"
    class="account-menu-btn"
    type="button"
    aria-label="Открыть личный кабинет"
    aria-haspopup="true"
    aria-expanded="false"
  >
    <svg
      id="accountMenuFallbackIcon"
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path
        d="M12 12.2a4.35 4.35 0 1 0 0-8.7
           4.35 4.35 0 0 0 0 8.7Zm0 2.1
           c-4.35 0-7.9 2.5-7.9 5.55
           0 .36.29.65.65.65h14.5
           c.36 0 .65-.29.65-.65
           0-3.05-3.55-5.55-7.9-5.55Z"
      />
    </svg>

    <img
      id="accountMenuPhoto"
      class="welder-photo-img hidden"
      alt="Фото сварщика"
    >

    <span
      id="accountMenuPhotoSpinner"
      class="welder-photo-spinner hidden"
      aria-hidden="true"
    ></span>

    <span class="account-menu-online"></span>
  </button>'''
replace_one(old,new,'account button')

# avatar block
old='''    <div class="account-menu-head">
      <div class="account-menu-avatar">
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path
            d="M12 12.2a4.35 4.35 0 1 0 0-8.7
               4.35 4.35 0 0 0 0 8.7Zm0 2.1
               c-4.35 0-7.9 2.5-7.9 5.55
               0 .36.29.65.65.65h14.5
               c.36 0 .65-.29.65-.65
               0-3.05-3.55-5.55-7.9-5.55Z"
          />
        </svg>
      </div>'''
new='''    <div class="account-menu-head">
      <button
        id="accountMenuAvatar"
        class="account-menu-avatar"
        type="button"
        aria-label="Открыть фото сварщика"
        onclick="welderPhotoOpenFromElement(this)"
      >
        <svg
          id="accountMenuAvatarFallbackIcon"
          viewBox="0 0 24 24"
          aria-hidden="true"
        >
          <path
            d="M12 12.2a4.35 4.35 0 1 0 0-8.7
               4.35 4.35 0 0 0 0 8.7Zm0 2.1
               c-4.35 0-7.9 2.5-7.9 5.55
               0 .36.29.65.65.65h14.5
               c.36 0 .65-.29.65-.65
               0-3.05-3.55-5.55-7.9-5.55Z"
          />
        </svg>

        <img
          id="accountMenuAvatarPhoto"
          class="welder-photo-img hidden"
          alt="Фото сварщика"
        >

        <span
          id="accountMenuAvatarSpinner"
          class="welder-photo-spinner hidden"
          aria-hidden="true"
        ></span>
      </button>'''
replace_one(old,new,'account avatar')

# modal before main
old='''</section>

<main>
<section id="loginView"'''
new='''</section>

<section
  id="welderPhotoModal"
  class="welder-photo-modal-backdrop hidden"
  role="dialog"
  aria-modal="true"
  aria-label="Фото сварщика"
  onclick="if(event.target===this)closeWelderPhotoModal()"
>
  <div class="welder-photo-modal">
    <div class="welder-photo-modal-image-wrap">
      <img
        id="welderPhotoModalImage"
        class="welder-photo-modal-image"
        alt="Фото сварщика"
      >
    </div>

    <div class="welder-photo-modal-actions">
      <button
        class="ghost"
        type="button"
        onclick="closeWelderPhotoModal()"
      >Закрыть</button>
    </div>
  </div>
</section>

<main>
<section id="loginView"'''
replace_one(old,new,'photo modal')

# uploader after ID cards view
old='''</section>
<section id="updaterView" class="hidden">'''
new='''</section>

<section id="welderPhotosUploaderView" class="hidden">
  <div class="glass login-wrap" style="margin-top:0;">
    <button
      id="backToStatAdminBtnPhotos"
      class="ghost small"
      type="button"
      style="margin-bottom:16px;"
    >← К журналу</button>

    <h2>Обновление фото сварщиков</h2>

    <div class="muted">
      Выберите ZIP-архив WelderPhotos, созданный скриптом Build-IDCards.ps1.
      Первый архив может быть очень большим — дождитесь завершения загрузки и распаковки.
    </div>

    <label for="welderPhotosArchiveInput">Архив фото</label>

    <input
      id="welderPhotosArchiveInput"
      type="file"
      accept=".zip,application/zip,application/x-zip-compressed"
    >

    <button
      id="uploadWelderPhotosBtn"
      style="width:100%;margin-top:18px;"
    >Загрузить фото на сервер</button>

    <div class="load-box" style="margin-top:16px;">
      <div class="load-row">
        <span id="welderPhotosUploadTitle">Ожидание архива…</span>
        <span id="welderPhotosUploadPct">0%</span>
      </div>

      <div class="bar">
        <span id="welderPhotosUploadBar"></span>
      </div>

      <div id="welderPhotosUploadDetails" class="load-details">
        Архив содержит manifest.json и фотографии по структуре КЛЕЙМО/photo.png.
      </div>
    </div>
  </div>
</section>

<section id="updaterView" class="hidden">'''
replace_one(old,new,'photo uploader view')

# stat admin button
replace_one(
'''      <button id="statUploadDbBtn" class="ghost small">Обновить базу</button>
      <button id="statUploadIdCardsBtn" class="ghost small">Обновить ID-карты</button>
      <span id="statAdminStatus" class="calc-status"></span>''',
'''      <button id="statUploadDbBtn" class="ghost small">Обновить базу</button>
      <button id="statUploadIdCardsBtn" class="ghost small">Обновить ID-карты</button>
      <button id="statUploadWelderPhotosBtn" class="ghost small">Обновить фото сварщиков</button>
      <span id="statAdminStatus" class="calc-status"></span>''',
'stat admin photo button')

replace_one(
'''  $("statUploadDbBtn").onclick=openStatUploadDb;$("statUploadIdCardsBtn").onclick=icOpenUploader;''',
'''  $("statUploadDbBtn").onclick=openStatUploadDb;$("statUploadIdCardsBtn").onclick=icOpenUploader;$("statUploadWelderPhotosBtn").onclick=welderPhotoOpenUploader;''',
'bind stat admin photo button')

# cache sync after manifest
replace_one(
'''    MANIFEST=await res.json();
    DB=DB||{meta:MANIFEST||{},auth:{},welders:[],welder_events:{},joints:[]};''',
'''    MANIFEST=await res.json();
    await welderPhotoSyncDbCacheVersion();
    DB=DB||{meta:MANIFEST||{},auth:{},welders:[],welder_events:{},joints:[]};''',
'cache invalidation hook')


# Immediate cache clear after successful main DB upload.
replace_one(
    'setUploadLoad("База обновлена",100,data.message||"Архив загружен. Обновите страницу у пользователей.");loadedShardCache.clear?.();',
    'setUploadLoad("База обновлена",100,data.message||"Архив загружен. Обновите страницу у пользователей.");loadedShardCache.clear?.();welderPhotoForceClearCache();',
    'immediate photo cache clear after DB upload'
)

# account menu loading hook
old='''    setValue(
      "accountWelderResponsible",
      welder.responsible
    );
  }
}'''
new='''    setValue(
      "accountWelderResponsible",
      welder.responsible
    );

    welderPhotoLoadAccountUi(welder);
  }else{
    welderPhotoResetAccountUi();
  }
}'''
replace_one(old,new,'account photo load hook')

# renderHeroWelder replacement
old='''function renderHeroWelder(w){
  const access=
    currentRole==="admin" &&
    welderAdminMode
      ?`<div
          id="heroAdminAccess"
          class="hero-admin-access"
        >
          <span class="hero-admin-access-title">
            Данные доступа
          </span>

          <span class="access-pill">
            <span class="muted">Логин:</span>
            <b id="heroAdminLogin">Загружаю…</b>
          </span>

          <span class="access-pill">
            <span class="muted">Пароль:</span>
            <b id="heroAdminPassword">Загружаю…</b>
          </span>
        </div>`
      :"";

  $("hero").innerHTML=`
    <div class="hero-content">
      <h2>${escapeHtml(w.name||"Сварщик")}</h2>

      <div class="hero-meta">
        Клеймо:
        <b>${escapeHtml(w.stamp||"—")}</b>
        · ${escapeHtml(w.organization||"—")}
        <br>
        ${escapeHtml(w.shift||"—")}
        · ${escapeHtml(w.position||"—")}
        · Нач. Участка/Прораб:
        ${escapeHtml(w.responsible||"—")}
      </div>

      ${access}
    </div>`;
}'''
new='''function renderHeroWelder(w){
  const showPhoto=
    currentRole==="admin" &&
    welderAdminMode;

  const photo=showPhoto
    ?`<button
        id="heroWelderPhoto"
        class="hero-welder-photo"
        type="button"
        aria-label="Открыть фото сварщика"
        onclick="welderPhotoOpenFromElement(this)"
      >
        <svg
          id="heroWelderPhotoFallback"
          viewBox="0 0 24 24"
          aria-hidden="true"
        >
          <path
            d="M12 12.2a4.35 4.35 0 1 0 0-8.7 4.35 4.35 0 0 0 0 8.7Zm0 2.1c-4.35 0-7.9 2.5-7.9 5.55 0 .36.29.65.65.65h14.5c.36 0 .65-.29.65-.65 0-3.05-3.55-5.55-7.9-5.55Z"
          />
        </svg>

        <img
          id="heroWelderPhotoImage"
          class="welder-photo-img hidden"
          alt="Фото сварщика"
        >

        <span
          id="heroWelderPhotoSpinner"
          class="welder-photo-spinner"
          aria-hidden="true"
        ></span>
      </button>`
    :"";

  const access=showPhoto
      ?`<div
          id="heroAdminAccess"
          class="hero-admin-access"
        >
          <span class="hero-admin-access-title">
            Данные доступа
          </span>

          <span class="access-pill">
            <span class="muted">Логин:</span>
            <b id="heroAdminLogin">Загружаю…</b>
          </span>

          <span class="access-pill">
            <span class="muted">Пароль:</span>
            <b id="heroAdminPassword">Загружаю…</b>
          </span>
        </div>`
      :"";

  $("hero").innerHTML=`
    ${photo}

    <div class="hero-content">
      <h2>${escapeHtml(w.name||"Сварщик")}</h2>

      <div class="hero-meta">
        Клеймо:
        <b>${escapeHtml(w.stamp||"—")}</b>
        · ${escapeHtml(w.organization||"—")}
        <br>
        ${escapeHtml(w.shift||"—")}
        · ${escapeHtml(w.position||"—")}
        · Нач. Участка/Прораб:
        ${escapeHtml(w.responsible||"—")}
      </div>

      ${access}
    </div>`;

  if(showPhoto){
    welderPhotoLoadHero(w);
  }
}'''
replace_one(old,new,'admin hero photo')

# logout hide photo uploader and reset account ui
old='''async function logout(){try{await fetch("/api/logout",{method:"POST",credentials:"same-origin"})}catch(e){}adminOrgFilter="";adminAccountFilterType="";adminAccountFilterValue="";currentSpkContractorId="";spkContractors=[];spkContractorsLoaded=false;spkBacklogHistory={};spkBacklogLoaded=false;spkPrecalc=null;clearSession();currentRole=null;currentWelder=null;selectedWelder=null;currentTab="total";$("appView").classList.add("hidden");$("loginView").classList.remove("hidden");$("logoutBtn").classList.add("hidden");$("updaterView")?.classList.add("hidden");$("statAdminView")?.classList.add("hidden");$("idCardsUploaderView")?.classList.add("hidden");setLoad("Вход готов",100,"Введите логин и пароль");suggShowBtn(false);$("engPhoneBtn").classList.add("hidden");welderAdminMode=false;syncHeaderBackToAdmin();}'''
new='''async function logout(){try{await fetch("/api/logout",{method:"POST",credentials:"same-origin"})}catch(e){}adminOrgFilter="";adminAccountFilterType="";adminAccountFilterValue="";currentSpkContractorId="";spkContractors=[];spkContractorsLoaded=false;spkBacklogHistory={};spkBacklogLoaded=false;spkPrecalc=null;clearSession();currentRole=null;currentWelder=null;selectedWelder=null;currentTab="total";$("appView").classList.add("hidden");$("loginView").classList.remove("hidden");$("logoutBtn").classList.add("hidden");$("updaterView")?.classList.add("hidden");$("statAdminView")?.classList.add("hidden");$("idCardsUploaderView")?.classList.add("hidden");$("welderPhotosUploaderView")?.classList.add("hidden");welderPhotoResetAccountUi();closeWelderPhotoModal();setLoad("Вход готов",100,"Введите логин и пароль");suggShowBtn(false);$("engPhoneBtn").classList.add("hidden");welderAdminMode=false;syncHeaderBackToAdmin();}'''
replace_one(old,new,'logout photo cleanup')

# Main JS block before ID cards
marker='''// === ID-KARTY ================================================================'''
if text.count(marker)!=1:
    raise SystemExit('ID marker count '+str(text.count(marker)))
js=r'''
// === WELDER PHOTOS ===========================================================
const WELDER_PHOTO_CACHE_NAME="statv2-welder-photos-v1";
const WELDER_PHOTO_DB_VERSION_KEY="statv2-welder-photos-db-version-v1";
const welderPhotoObjectUrls=new Map();
const welderPhotoLoads=new Map();

function welderPhotoDbVersion(){
  const manifest=MANIFEST||{};
  return String(
    manifest.base_version||
    manifest.generated_at||
    manifest.files?.auth?.sha256||
    "0"
  );
}

function welderPhotoRevokeObjectUrls(){
  for(const url of welderPhotoObjectUrls.values()){
    try{URL.revokeObjectURL(url)}catch(e){}
  }
  welderPhotoObjectUrls.clear();
  welderPhotoLoads.clear();
}

async function welderPhotoForceClearCache(){
  try{
    if("caches" in window){
      await caches.delete(WELDER_PHOTO_CACHE_NAME);
    }
  }catch(e){
    console.warn("Не удалось очистить кэш фото:",e);
  }

  try{
    localStorage.removeItem(WELDER_PHOTO_DB_VERSION_KEY);
  }catch(e){}

  welderPhotoRevokeObjectUrls();
  welderPhotoResetAccountUi();
}

async function welderPhotoSyncDbCacheVersion(){
  const current=welderPhotoDbVersion();
  if(!current||current==="0")return;

  let previous="";
  try{
    previous=localStorage.getItem(WELDER_PHOTO_DB_VERSION_KEY)||"";
  }catch(e){}

  if(previous&&previous!==current){
    try{
      if("caches" in window){
        await caches.delete(WELDER_PHOTO_CACHE_NAME);
      }
    }catch(e){
      console.warn("Не удалось очистить кэш фото:",e);
    }

    welderPhotoRevokeObjectUrls();
  }

  try{
    localStorage.setItem(WELDER_PHOTO_DB_VERSION_KEY,current);
  }catch(e){}
}

function welderPhotoUrl(stamp){
  return "/api/welder_photo/"+encodeURIComponent(String(stamp||"").trim());
}

async function welderPhotoGetObjectUrl(stamp){
  stamp=String(stamp||"").trim().toUpperCase();
  if(!stamp)return null;

  if(welderPhotoObjectUrls.has(stamp)){
    return welderPhotoObjectUrls.get(stamp);
  }

  if(welderPhotoLoads.has(stamp)){
    return welderPhotoLoads.get(stamp);
  }

  const promise=(async()=>{
    const url=welderPhotoUrl(stamp);
    let response=null;

    try{
      if("caches" in window){
        const cache=await caches.open(WELDER_PHOTO_CACHE_NAME);
        response=await cache.match(url);

        if(!response&&navigator.onLine){
          const fresh=await fetch(url,{
            cache:"no-store",
            credentials:"same-origin",
          });

          if(fresh.status===404)return null;
          if(!fresh.ok)throw new Error("HTTP "+fresh.status);

          await cache.put(url,fresh.clone());
          response=fresh;
        }
      }else if(navigator.onLine){
        response=await fetch(url,{
          cache:"force-cache",
          credentials:"same-origin",
        });

        if(response.status===404)return null;
        if(!response.ok)throw new Error("HTTP "+response.status);
      }

      if(!response)return null;

      const blob=await response.blob();
      if(!blob.size)return null;

      const objectUrl=URL.createObjectURL(blob);
      welderPhotoObjectUrls.set(stamp,objectUrl);
      return objectUrl;

    }finally{
      welderPhotoLoads.delete(stamp);
    }
  })();

  welderPhotoLoads.set(stamp,promise);
  return promise;
}

function welderPhotoSetLoading(imageId,spinnerId,fallbackId,containerId){
  const image=$(imageId);
  const spinner=$(spinnerId);
  const fallback=$(fallbackId);
  const container=$(containerId);

  if(image){
    image.classList.add("hidden");
    image.removeAttribute("src");
  }
  spinner?.classList.remove("hidden");
  fallback?.classList.add("hidden");
  container?.classList.remove("welder-photo-ready");
  if(container)delete container.dataset.photoUrl;
}

function welderPhotoSetFallback(imageId,spinnerId,fallbackId,containerId){
  const image=$(imageId);
  const spinner=$(spinnerId);
  const fallback=$(fallbackId);
  const container=$(containerId);

  if(image){
    image.classList.add("hidden");
    image.removeAttribute("src");
  }
  spinner?.classList.add("hidden");
  fallback?.classList.remove("hidden");
  container?.classList.remove("welder-photo-ready");
  if(container)delete container.dataset.photoUrl;
}

function welderPhotoSetReady(url,imageId,spinnerId,fallbackId,containerId){
  const image=$(imageId);
  const spinner=$(spinnerId);
  const fallback=$(fallbackId);
  const container=$(containerId);

  if(image){
    image.src=url;
    image.classList.remove("hidden");
  }
  spinner?.classList.add("hidden");
  fallback?.classList.add("hidden");
  container?.classList.add("welder-photo-ready");
  if(container)container.dataset.photoUrl=url;
}

async function welderPhotoLoadInto(stamp,imageId,spinnerId,fallbackId,containerId){
  welderPhotoSetLoading(imageId,spinnerId,fallbackId,containerId);

  try{
    const url=await welderPhotoGetObjectUrl(stamp);
    if(!url){
      welderPhotoSetFallback(imageId,spinnerId,fallbackId,containerId);
      return;
    }

    welderPhotoSetReady(url,imageId,spinnerId,fallbackId,containerId);
  }catch(e){
    welderPhotoSetFallback(imageId,spinnerId,fallbackId,containerId);
    console.warn("Фото сварщика:",e);
  }
}

function welderPhotoResetAccountUi(){
  welderPhotoSetFallback(
    "accountMenuPhoto",
    "accountMenuPhotoSpinner",
    "accountMenuFallbackIcon",
    "accountMenuBtn"
  );

  welderPhotoSetFallback(
    "accountMenuAvatarPhoto",
    "accountMenuAvatarSpinner",
    "accountMenuAvatarFallbackIcon",
    "accountMenuAvatar"
  );
}

function welderPhotoLoadAccountUi(welder){
  const stamp=String(welder?.stamp||"").trim();
  if(!stamp){
    welderPhotoResetAccountUi();
    return;
  }

  welderPhotoLoadInto(
    stamp,
    "accountMenuPhoto",
    "accountMenuPhotoSpinner",
    "accountMenuFallbackIcon",
    "accountMenuBtn"
  );

  welderPhotoLoadInto(
    stamp,
    "accountMenuAvatarPhoto",
    "accountMenuAvatarSpinner",
    "accountMenuAvatarFallbackIcon",
    "accountMenuAvatar"
  );
}

function welderPhotoLoadHero(welder){
  const stamp=String(welder?.stamp||"").trim();

  if(!stamp){
    welderPhotoSetFallback(
      "heroWelderPhotoImage",
      "heroWelderPhotoSpinner",
      "heroWelderPhotoFallback",
      "heroWelderPhoto"
    );
    return;
  }

  welderPhotoLoadInto(
    stamp,
    "heroWelderPhotoImage",
    "heroWelderPhotoSpinner",
    "heroWelderPhotoFallback",
    "heroWelderPhoto"
  );
}

function welderPhotoOpenFromElement(element){
  const url=element?.dataset?.photoUrl||"";
  if(!url)return;

  const modal=$("welderPhotoModal");
  const image=$("welderPhotoModalImage");
  if(!modal||!image)return;

  image.src=url;
  modal.classList.remove("hidden");
  document.body.style.overflow="hidden";
}

function closeWelderPhotoModal(){
  $("welderPhotoModal")?.classList.add("hidden");
  document.body.style.overflow="";
}

function welderPhotoUploadSet(title,pct,details=""){
  const p=Math.max(0,Math.min(100,Number(pct)||0));
  if($("welderPhotosUploadTitle"))$("welderPhotosUploadTitle").textContent=title;
  if($("welderPhotosUploadPct"))$("welderPhotosUploadPct").textContent=Math.round(p)+"%";
  if($("welderPhotosUploadBar"))$("welderPhotosUploadBar").style.width=p+"%";
  if($("welderPhotosUploadDetails"))$("welderPhotosUploadDetails").textContent=details;
}

function welderPhotoOpenUploader(){
  [
    "adminView",
    "welderView",
    "updaterView",
    "statAdminView",
    "idCardsUploaderView",
  ].forEach(id=>$(id)?.classList.add("hidden"));

  $("welderPhotosUploaderView")?.classList.remove("hidden");

  welderPhotoUploadSet(
    "Ожидание архива…",
    0,
    "Выберите WelderPhotos_*.zip. Первый архив может весить около 800 МБ."
  );
}

function welderPhotoBackToStatAdmin(){
  $("welderPhotosUploaderView")?.classList.add("hidden");
  $("statAdminView")?.classList.remove("hidden");
}

function welderPhotoFormatMb(value){
  return (Number(value||0)/1024/1024).toFixed(1)+" МБ";
}

function welderPhotoUploadArchive(){
  const input=$("welderPhotosArchiveInput");
  const button=$("uploadWelderPhotosBtn");
  const file=input?.files?.[0];

  if(!file){
    alert("Выберите ZIP-файл с фотографиями");
    return;
  }

  if(!/\.zip$/i.test(file.name||"")){
    alert("Нужен ZIP-архив");
    return;
  }

  if(button)button.disabled=true;

  welderPhotoUploadSet(
    "Подготовка загрузки…",
    0,
    `${file.name} · ${welderPhotoFormatMb(file.size)}`
  );

  const xhr=new XMLHttpRequest();
  xhr.open("POST","/api/upload_welder_photos",true);
  xhr.withCredentials=true;
  xhr.timeout=0;

  xhr.upload.onprogress=event=>{
    if(!event.lengthComputable)return;

    const pct=Math.round(event.loaded/event.total*100);

    welderPhotoUploadSet(
      "Загрузка фото на сервер…",
      pct,
      `${welderPhotoFormatMb(event.loaded)} из ${welderPhotoFormatMb(event.total)}`
    );
  };

  xhr.upload.onload=()=>{
    welderPhotoUploadSet(
      "Архив передан. Распаковываю на сервере…",
      100,
      "Не закрывайте страницу до ответа сервера. На первом архиве это может занять несколько минут."
    );
  };

  xhr.onload=()=>{
    if(button)button.disabled=false;

    let data={};
    try{data=JSON.parse(xhr.responseText||"{}")}catch(e){}

    if(xhr.status>=200&&xhr.status<300&&data.ok){
      welderPhotoUploadSet(
        "Готово!",
        100,
        `Добавлено файлов: ${data.files_added||0} · всего клейм: ${data.welders||0} · распаковано: ${welderPhotoFormatMb(data.bytes_added||0)}`
      );
      return;
    }

    welderPhotoUploadSet(
      "Ошибка загрузки",
      0,
      data.error||(`HTTP ${xhr.status}`)
    );
  };

  xhr.onerror=()=>{
    if(button)button.disabled=false;
    welderPhotoUploadSet(
      "Ошибка сети",
      0,
      "Соединение оборвалось во время загрузки."
    );
  };

  xhr.onabort=()=>{
    if(button)button.disabled=false;
    welderPhotoUploadSet(
      "Загрузка отменена",
      0,
      "Архив не был загружен."
    );
  };

  const form=new FormData();
  form.append("file",file);
  xhr.send(form);
}

$("uploadWelderPhotosBtn")?.addEventListener("click",welderPhotoUploadArchive);
$("backToStatAdminBtnPhotos")?.addEventListener("click",welderPhotoBackToStatAdmin);

document.addEventListener("keydown",event=>{
  if(event.key==="Escape"){
    closeWelderPhotoModal();
  }
});

'''
text=text.replace(marker,js+marker,1)
print('OK photo JS')

required=['statUploadWelderPhotosBtn','welderPhotosUploaderView','/api/upload_welder_photos','/api/welder_photo/','WELDER_PHOTO_CACHE_NAME','heroWelderPhoto','accountMenuPhoto','accountMenuAvatarPhoto','welderPhotoSyncDbCacheVersion','welderPhotoModal']
for x in required:
    if x not in text: raise SystemExit('missing '+x)

path.write_text(text,encoding='utf-8')
print('DONE',path)
