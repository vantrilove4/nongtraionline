(()=>{
  'use strict';

  const ROOT='assets/audio/';
  const MUSIC={
    'Xuân':ROOT+'music/spring-morning.ogg',
    'Hạ':ROOT+'music/morning-brew.ogg',
    'Thu':ROOT+'music/pumpkin-patch.ogg',
    'Đông':ROOT+'music/snowy-village.ogg'
  };
  const BIRDS=ROOT+'ambient/birds.mp3';
  const WIND=ROOT+'ambient/wind.ogg';
  const WATER=ROOT+'ambient/water.mp3';
  const RAIN=[1,2,3,4].map(n=>ROOT+'ambient/rain-'+n+'.ogg');
  const ANIMALS={chicken:[ROOT+'animals/chicken.ogg'],cow:[ROOT+'animals/cow.ogg'],pig:[ROOT+'animals/pig.mp3']};
  const STORE_KEY='vuonnho_audio_v1';
  const clamp=(n,min=0,max=1)=>Math.max(min,Math.min(max,Number(n)||0));

  function readSettings(){
    let oldMusic=true;
    try{oldMusic=localStorage.getItem('vuonnho_music')!=='off'}catch{}
    try{
      const saved=JSON.parse(localStorage.getItem(STORE_KEY)||'null');
      if(saved&&typeof saved==='object')return{
        enabled:saved.enabled!==false,
        musicOn:saved.musicOn!==false,
        music:clamp(saved.music,.0,1),
        ambient:clamp(saved.ambient,.0,1)
      };
    }catch{}
    return{enabled:true,musicOn:oldMusic,music:.32,ambient:.46};
  }

  const failedSources=new Set();
  const settings=readSettings();
  const saveSettings=()=>{try{localStorage.setItem(STORE_KEY,JSON.stringify(settings));localStorage.setItem('vuonnho_music',settings.musicOn?'on':'off')}catch{}};
  const makeAudio=()=>{
    const audio=new Audio();
    audio.preload='none';
    audio.volume=0;
    audio.addEventListener('error',()=>{const path=audio.dataset.src||audio.currentSrc||audio.src;if(path&&!failedSources.has(path)){failedSources.add(path);console.warn('Không tải được âm thanh nông trại:',path)}});
    return audio;
  };
  const makeSlot=()=>({channels:[makeAudio(),makeAudio()],active:null,src:'',gain:0,token:0});
  const music=makeSlot(),ambience=makeSlot(),weatherBed=makeSlot();
  let unlocked=false,hidden=document.hidden,scene={x:0,y:0,season:'Xuân',weather:{kind:'clear'},animals:{},zones:[]};
  let activeZone='outside',eventTimer=0,eventAudio=null,lastRain='',lastWeatherKey='';
  const zoneRects={
    fish:{x:0,y:700,w:370,h:270},cow:{x:415,y:700,w:470,h:270},
    chicken:{x:910,y:700,w:470,h:270},pig:{x:1420,y:700,w:450,h:270}
  };
  const gardenRect={x:345,y:220,w:875,h:320};

  function fade(audio,to,duration=1300,pauseAtZero=false,slot=null){
    const token=(audio.__farmFadeToken||0)+1;
    audio.__farmFadeToken=token;
    const from=Number.isFinite(audio.volume)?audio.volume:0;
    if(!duration){audio.volume=clamp(to);if(pauseAtZero&&to===0)audio.pause();return token}
    const started=performance.now();
    const step=now=>{
      if(audio.__farmFadeToken!==token)return;
      const p=clamp((now-started)/duration);
      audio.volume=clamp(from+(to-from)*p);
      if(p<1)requestAnimationFrame(step);
      else if(pauseAtZero&&to===0){audio.pause();try{audio.currentTime=0}catch{} }
    };
    requestAnimationFrame(step);
    return token;
  }

  function channelVolume(slot){
    if(!settings.enabled||hidden)return 0;
    const base=slot===music?(settings.musicOn?settings.music:0):settings.ambient;
    return clamp(base*slot.gain);
  }
  function setSlotGain(slot,gain){slot.gain=clamp(gain);if(slot.active)fade(slot.active,channelVolume(slot),300)}
  function stopSlot(slot,duration=1400){
    slot.token++;
    const old=slot.active;slot.active=null;slot.src='';
    for(const audio of slot.channels)fade(audio,0,duration,true,slot);
  }
  function setLoop(slot,src,gain=1,duration=1450){
    slot.gain=clamp(gain);
    const nextSrc=settings.enabled&&!hidden&&(slot!==music||settings.musicOn)?src:'';
    if(!nextSrc){if(slot.active)stopSlot(slot,duration);return}
    if(failedSources.has(nextSrc))return;
    if(slot.src===nextSrc&&slot.active&&!slot.active.paused){fade(slot.active,channelVolume(slot),450);return}
    const token=++slot.token,old=slot.active,next=slot.channels.find(audio=>audio!==old)||slot.channels[0];
    slot.src=nextSrc;slot.active=next;next.pause();next.loop=true;next.dataset.src=nextSrc;
    if(next.src!==new URL(nextSrc,document.baseURI).href)next.src=nextSrc;
    try{next.currentTime=0}catch{}
    next.volume=0;
    next.play().then(()=>{
      if(token!==slot.token||slot.active!==next){next.pause();return}
      fade(next,channelVolume(slot),duration);
      if(old){const oldToken=fade(old,0,duration,true,slot);setTimeout(()=>{if(old.__farmFadeToken===oldToken)old.pause()},duration+60)}
    }).catch(error=>{
      if(token!==slot.token)return;
      failedSources.add(nextSrc);
      console.warn('Âm thanh bị chặn hoặc không khả dụng:',nextSrc,error);
      slot.active=null;slot.src='';
    });
  }
  function syncVolumes(){
    for(const slot of [music,ambience,weatherBed])if(slot.active)fade(slot.active,channelVolume(slot),220);
    if(eventAudio)eventAudio.volume=clamp(settings.enabled&&!hidden?settings.ambient*.52:0);
  }
  function distanceToRect(point,rect){
    const dx=Math.max(rect.x-point.x,0,point.x-(rect.x+rect.w));
    const dy=Math.max(rect.y-point.y,0,point.y-(rect.y+rect.h));
    return Math.hypot(dx,dy);
  }
  function classifyZone(){
    const p={x:Number(scene.x)||0,y:Number(scene.y)||0};
    const order=['chicken','cow','pig','fish'];
    const rectangles={...zoneRects};
    for(const zone of scene.zones||[])if(zoneRects[zone.key])rectangles[zone.key]=zone;
    const isAvailable=key=>(Number(scene.animals?.[key])||0)>0||key==='fish';
    // Pens are fenced, so let the sound trigger from just outside the pen too.
    // Keep a little hysteresis to prevent the selected pen flickering at edges.
    if(activeZone!=='outside'&&activeZone!=='garden'&&isAvailable(activeZone)&&distanceToRect(p,rectangles[activeZone]||zoneRects[activeZone])<78)return activeZone;
    let nearest='',nearestDistance=Infinity;
    for(const key of order){
      if(!isAvailable(key))continue;
      const distance=distanceToRect(p,rectangles[key]);
      if(distance<=60&&distance<nearestDistance){nearest=key;nearestDistance=distance}
    }
    if(nearest)return nearest;
    if(distanceToRect(p,gardenRect)<=0)return'garden';
    return'outside';
  }
  function rainPath(){
    if(!lastRain)lastRain=RAIN[Math.floor(Math.random()*RAIN.length)];
    return lastRain;
  }
  function clearEvent(){if(eventTimer){clearTimeout(eventTimer);eventTimer=0}if(eventAudio){eventAudio.onended=null;fade(eventAudio,0,180,true);eventAudio=null}}
  function playOneShot(path,volume=.55){
    if(!settings.enabled||hidden||!unlocked||failedSources.has(path)||eventAudio&&!eventAudio.paused)return false;
    const audio=makeAudio();eventAudio=audio;audio.preload='none';audio.loop=false;audio.src=path;audio.volume=clamp(settings.ambient*volume);
    audio.onended=()=>{if(eventAudio===audio)eventAudio=null};
    audio.play().catch(error=>{failedSources.add(path);if(eventAudio===audio)eventAudio=null;console.warn('Âm thanh môi trường không khả dụng:',path,error)});
    return true;
  }
  function scheduleZoneEvent(zone,firstInZone=false){
    if(eventTimer){clearTimeout(eventTimer);eventTimer=0}
    if(!unlocked||!settings.enabled||hidden)return;
    let path='',delay=0,volume=.5;
    if(zone==='garden'){
      path=BIRDS;delay=scene.season==='Đông'?26000+Math.random()*22000:14000+Math.random()*18000;volume=scene.season==='Đông'?.24:.4;
    }else if(zone==='fish'){
      path=WATER;delay=firstInZone?1200+Math.random()*1800:15000+Math.random()*18000;volume=.34;
    }else if(ANIMALS[zone]&&(Number(scene.animals?.[zone])||0)>0){
      const options=ANIMALS[zone];path=options[Math.floor(Math.random()*options.length)];delay=firstInZone?1200+Math.random()*1800:16000+Math.random()*20000;volume=.72;
    }else return;
    eventTimer=setTimeout(()=>{
      eventTimer=0;
      if(activeZone!==zone||!settings.enabled||hidden)return;
      playOneShot(path,volume);
      scheduleZoneEvent(zone);
    },delay);
  }
  function updateEnvironment(){
    if(!unlocked)return;
    const zone=classifyZone(),weatherKind=scene.weather?.kind||'clear',season=scene.season||'Xuân';
    if(zone!==activeZone){clearEvent();activeZone=zone;scheduleZoneEvent(zone,true)}
    const musicPath=MUSIC[season]||MUSIC['Xuân'];
    setLoop(music,musicPath,.86,1800);
    setLoop(ambience,'',0,1500);
    let weatherPath='';
    if(weatherKind==='rain'||weatherKind==='storm'||weatherKind==='drizzle'){
      if(lastWeatherKey!==weatherKind||!lastRain)lastRain=RAIN[Math.floor(Math.random()*RAIN.length)];
      weatherPath=lastRain;
    }else if(season==='Đông'||season==='Thu'||weatherKind==='snow'||(weatherKind==='cloud'||weatherKind==='overcast')){
      weatherPath=WIND;
    }
    if(weatherKind!==lastWeatherKey){lastWeatherKey=weatherKind;if(weatherKind!=='rain'&&weatherKind!=='storm'&&weatherKind!=='drizzle')lastRain=''}
    const weatherGain=weatherPath===WIND?.16:weatherPath?.21:0;
    setLoop(weatherBed,weatherPath,weatherGain,1800);
  }
  function pauseAll(){
    hidden=true;clearEvent();
    for(const slot of [music,ambience,weatherBed])for(const audio of slot.channels){audio.volume=0;audio.pause()}
  }
  function resumeAll(){
    hidden=false;
    if(unlocked)updateEnvironment();
  }
  document.addEventListener('visibilitychange',()=>document.hidden?pauseAll():resumeAll());
  window.addEventListener('pagehide',pauseAll);
  window.addEventListener('pageshow',()=>{if(!document.hidden)resumeAll()});

  window.VuonNhoAudioManager={
    unlock(){
      if(!settings.enabled||hidden)return;
      unlocked=true;
      updateEnvironment();
    },
    update(next){scene={...scene,...next};if(unlocked)updateEnvironment()},
    getSettings(){return{...settings}},
    setEnabled(value){settings.enabled=!!value;saveSettings();if(settings.enabled){unlocked=true;updateEnvironment()}else{for(const slot of [music,ambience,weatherBed])stopSlot(slot,320);clearEvent()}},
    setMusicEnabled(value){settings.musicOn=!!value;if(settings.musicOn)unlocked=true;saveSettings();if(settings.musicOn){if(unlocked)updateEnvironment()}else stopSlot(music,500)},
    setMusicVolume(value){settings.music=clamp(value);saveSettings();syncVolumes()},
    setAmbientVolume(value){settings.ambient=clamp(value);saveSettings();syncVolumes()},
    refresh(){syncVolumes();if(unlocked)updateEnvironment()}
  };
})();
