/* Shared renderer: native WKWebView preview and authenticated Runtime ingress. */
(() => {
  'use strict';
  const root = document.getElementById('dashboard');
  let options={}, payload={}, documentModel=null, pageID='', selected='', values={}, signature='', published=null, loading=false, sequence=0, timer=null;
  const nodes=new Map(), inflight=new Set(), histories=new Map(), pausedCameras=new Set();
  let cameraTimer=null; const reduceMotion=matchMedia("(prefers-reduced-motion: reduce)");
  const columns={desktop:12,tablet:8,mobile:4};
  const defaultTitles={weather:'Wetter',climate:'Raumklima',scene:'Szene',text:'Text',camera:'Kamera',image:'Bild',graph:'Livegraph',value:'Wertanzeige',light:'Licht',switch:'Schalter'};
  const icons={light:'M9 18h6M10 21h4M8 14a6 6 0 1 1 8 0c-1 1-1 2-1 2H9s0-1-1-2',switch:'M12 3v9M7 5a8 8 0 1 0 10 0',camera:'M3 5h12v14H3zM15 10l6-4v12l-6-4',graph:'M3 3v18h18M5 16l4-5 4 2 7-9',value:'M4 9h16M3 15h16M10 3 8 21M17 3l-2 18',text:'M4 5h16M12 5v15M8 20h8',image:'M3 3h18v18H3zM3 17l6-6 4 4 3-3 5 5'};
  function el(tag,cls,text){const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=text;return n;}
  function bridge(message){window.webkit?.messageHandlers?.dashboard?.postMessage(message);}
  function viewport(){return payload.viewport||((root.clientWidth<560)?'mobile':root.clientWidth<880?'tablet':'desktop');}
  function frame(c){return c.layouts[viewport()]||{x:0,y:0,width:4,height:3};}
  function setFrame(n,f){n.style.gridColumn=`${f.x+1} / span ${f.width}`;n.style.gridRow=`${f.y+1} / span ${f.height}`;}
  function icon(kind){const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('viewBox','0 0 24 24');svg.setAttribute('aria-hidden','true');const p=document.createElementNS(svg.namespaceURI,'path');p.setAttribute('d',icons[kind]||icons.value);svg.append(p);return svg;}
  function theme(){const t=documentModel.theme;document.documentElement.dataset.palette=t.palette||"slate";root.style.setProperty('--accent',t.accent);root.style.setProperty('--radius',t.radius+'px');root.style.setProperty('--gap',t.spacing+'px');document.documentElement.style.setProperty('--size',t.fontSize+'px');document.documentElement.style.colorScheme=t.appearance==='system'?'light dark':t.appearance;root.style.fontFamily=t.font==='rounded'?'ui-rounded,-apple-system,sans-serif':t.font==='serif'?'ui-serif,Georgia,serif':'-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif';}
  function render(){
    if(!documentModel)return;stopCameras();theme();root.replaceChildren();nodes.clear();root.classList.toggle('dash-edit',options.mode==='editor'&&!payload.preview);
    const head=el('header','dash-heading'),titles=el('div','dash-titles');titles.append(el('h1','',documentModel.title));if(documentModel.subtitle)titles.append(el('p','dash-subtitle',documentModel.subtitle));head.append(titles);if(documentModel.showClock){const clock=el('div','dash-clock');clock.append(el('small','clock-date'),el('div','clock-time'));head.append(clock);}root.append(head);
    const sideNav=options.mode==='viewer'?document.getElementById('dashboard-page-nav'):null;
    const nav=sideNav||el('nav','dash-pages');nav.replaceChildren();nav.setAttribute('aria-label','Dashboard-Seiten');
    if(sideNav){sideNav.hidden=false;sideNav.append(el('span','nav-section-title','Seiten'));}
    const page=documentModel.pages.find(p=>p.id===pageID)||documentModel.pages[0];pageID=page.id;
    for(const p of documentModel.pages){const b=el('button','',p.title);b.setAttribute('aria-pressed',String(p.id===pageID));if(p.id===pageID)b.setAttribute('aria-current','page');b.onclick=()=>{pageID=p.id;bridge({type:'page',id:p.id});render();};nav.append(b);}if(!sideNav)root.append(nav);
    const grid=el('div','dash-grid');grid.style.setProperty('--columns',columns[viewport()]);root.append(grid);
    if(!page.components.length)grid.append(el('div','dash-empty',options.mode==='editor'?'Füge links deine erste Komponente hinzu.':'Diese Seite enthält noch keine Inhalte.'));
    for(const c of page.components){
      const card=el('section','dash-widget');card.dataset.kind=c.kind;card.dataset.effect=c.effect||'none';card.dataset.id=c.id;card.setAttribute('aria-label',c.title);setFrame(card,frame(c));card.classList.toggle('selected',selected===c.id&&!payload.preview&&options.mode==='editor');
      // Component types belong in the editor library, not in the finished design.
      if(c.showTitle!==false&&c.title.trim()&&c.title.trim()!==defaultTitles[c.kind]){const top=el('div','widget-top');top.append(el('span','widget-title',c.title));card.append(top);}
      const asset=documentModel.assets.find(a=>a.id===c.assetID);
      if(asset&&c.kind!=='image'&&c.kind!=='camera'){const photo=el('img','widget-backdrop');photo.alt='';photo.src=`data:${asset.mime};base64,${asset.data}`;card.prepend(photo);card.classList.add('has-backdrop');}
      const value=el('div','widget-value'),feedback=el('div','widget-feedback');feedback.setAttribute('aria-live','polite');
      if(c.kind==='weather'){card.dataset.weather=c.weather?.style||'minimal';card.append(el('div','weather-condition'),value,el('div','weather-details'));}
      else if(c.kind==='text')card.append(el('div','widget-text',c.text));
      else if(c.kind==='image'){const a=documentModel.assets.find(a=>a.id===c.assetID);if(a){const img=el('img','widget-image');img.alt=c.title;img.src=`data:${a.mime};base64,${a.data}`;card.append(img);}else card.append(el('div','widget-text','Bild auswählen'));}
      else if(c.kind==='camera'){const img=el('img','widget-image widget-camera');img.alt=c.title;card.append(img);card.append(value);if(options.mode==='viewer'){const pause=el('button','camera-pause','Livebild pausieren');pause.onclick=()=>{pausedCameras.has(c.id)?pausedCameras.delete(c.id):pausedCameras.add(c.id);cameraTick();};card.append(pause);}}
      else if(c.kind==='graph'){card.append(value);const chart=document.createElementNS('http://www.w3.org/2000/svg','svg');chart.classList.add('widget-chart');chart.setAttribute('viewBox','0 0 320 100');chart.setAttribute('preserveAspectRatio','none');chart.setAttribute('role','img');chart.setAttribute('aria-label',c.title+' · Liveverlauf');const path=document.createElementNS(chart.namespaceURI,'path');path.classList.add('chart-line');chart.append(path);card.append(chart,el('small','chart-caption','Liveverlauf seit dem Öffnen'));}
      else card.append(value);
      const controls=[];
      if(c.kind==='scene'){const b=el('button','scene-activate','Aktivieren');b.onclick=()=>act(c,{on:true});controls.push(b);card.append(b,feedback);}
      if(c.kind==='climate'){
        const row=el('div','climate-controls'),temperature=el('input','climate-target');temperature.type='number';temperature.setAttribute('aria-label',c.title+' · Zieltemperatur');temperature.onchange=()=>{if(temperature.value!==''&&temperature.checkValidity())act(c,{temperature:Number(temperature.value)});};
        row.append(el('span','','Zieltemperatur'),temperature);card.append(row,feedback);controls.push(temperature);
      }
      if(c.kind==='light'||c.kind==='switch'){
        const actions=el('div','widget-actions');for(const on of [true,false]){const b=el('button','',on?'Ein':'Aus');b.dataset.on=String(on);b.onclick=()=>act(c,{on});controls.push(b);actions.append(b);}card.append(actions);
        if(c.kind==='light'&&!c.brightnessBinding){const slider=el('input','widget-slider');slider.type='range';slider.min='1';slider.max='100';slider.value='50';slider.setAttribute('aria-label',c.title+' · Helligkeit');slider.onchange=()=>act(c,{on:true,brightness:Number(slider.value)});card.append(slider);controls.push(slider);}
        card.append(feedback);
      }
      if(options.mode==='editor'&&!payload.preview){
        for(const direction of ['nw','n','ne','e','se','s','sw','w']){const resize=el('button','dash-resize handle-'+direction);resize.dataset.direction=direction;resize.setAttribute('aria-label',c.title+' · Größe ändern '+direction);card.append(resize);}
        const label=el('span','selection-label',c.title);card.append(label);
        card.onpointerdown=e=>drag(e,c,card,e.target.dataset?.direction||'');card.onclick=()=>{selected=c.id;bridge({type:'select',id:c.id});markSelection();};
      }
      nodes.set(c.id,{card,value,feedback,controls,c,camera:card.querySelector('.widget-camera'),cameraAt:0,cameraError:false,graph:card.querySelector('.chart-line')});grid.append(card);
    }
    root.append(el('div','dash-status',options.mode==='editor'?'Gestaltungsvorschau · Werte nur lesend':'Verbindung wird geprüft …'));applyValues();
  }
  function markSelection(){for(const [id,n] of nodes)n.card.classList.toggle('selected',id===selected&&!payload.preview&&options.mode==='editor');}
  function drag(e,c,card,resizing){
    if(e.button!==0)return;e.preventDefault();selected=c.id;bridge({type:'select',id:c.id});markSelection();
    const start={x:e.clientX,y:e.clientY}, original={...frame(c)}, grid=card.parentElement, gap=documentModel.theme.spacing, cw=(grid.clientWidth-(columns[viewport()]-1)*gap)/columns[viewport()]+gap,rh=48+gap;let current=original;
    card.setPointerCapture(e.pointerId);
    const move=event=>{
      const dx=Math.round((event.clientX-start.x)/cw),dy=Math.round((event.clientY-start.y)/rh);
      current={...original};
      if(resizing){
        if(resizing.includes('e'))current.width=Math.max(1,Math.min(columns[viewport()]-original.x,original.width+dx));
        if(resizing.includes('s'))current.height=Math.max(2,Math.min(12,original.height+dy));
        if(resizing.includes('w')){current.x=Math.max(0,Math.min(original.x+original.width-1,original.x+dx));current.width=original.width+original.x-current.x;}
        if(resizing.includes('n')){current.y=Math.max(0,Math.min(original.y+original.height-2,original.y+dy));current.height=Math.min(12,original.height+original.y-current.y);current.y=original.y+original.height-current.height;}
      } else {current.x=Math.max(0,Math.min(columns[viewport()]-original.width,original.x+dx));current.y=Math.max(0,Math.min(100,original.y+dy));}
      setFrame(card,current);grid.classList.add('is-dragging');
    };
    const finish=event=>{grid.classList.remove('is-dragging');card.removeEventListener('pointermove',move);card.removeEventListener('pointerup',finish);card.removeEventListener('pointercancel',cancel);if(card.hasPointerCapture(event.pointerId))card.releasePointerCapture(event.pointerId);if(JSON.stringify(current)!==JSON.stringify(original)){c.layouts[viewport()]=current;bridge({type:'layout',id:c.id,viewport:viewport(),frame:current});}};
    const cancel=event=>{current=original;setFrame(card,original);finish(event);};card.addEventListener('pointermove',move);card.addEventListener('pointerup',finish);card.addEventListener('pointercancel',cancel);
  }
  function applyValues(){
    const now=new Date(),clock=root.querySelector('.dash-clock');if(clock){clock.querySelector('.clock-date').textContent=now.toLocaleDateString('de-DE',{weekday:'short',day:'numeric',month:'short',year:'numeric'});clock.querySelector('.clock-time').textContent=now.toLocaleTimeString('de-DE',{hour:'2-digit',minute:'2-digit'});}
    for(const [id,n] of nodes){
      const v=values[id],known=v?.known===true;let text=known?String(v.value):v?.reason||'Wert nicht verfügbar';
      if(known&&typeof v.value==='boolean')text=v.value?'Ein':'Aus';
      if(known&&['light','switch'].includes(n.c.kind)&&['on','off'].includes(v.value))text=v.value==='on'?'Ein':'Aus';
      if(known&&typeof v.value==='number')text=new Intl.NumberFormat('de-DE',{maximumFractionDigits:2}).format(v.value);
      if(known&&n.c.unit)text+=' '+n.c.unit;
      if(known&&n.c.kind==='climate')text=Number.isFinite(v.temperature)?new Intl.NumberFormat('de-DE',{maximumFractionDigits:1}).format(v.temperature)+'°':String(v.value);
      if(known&&n.c.kind==='scene')text='Bereit';
      if(n.c.kind==='camera'){text=known?(options.mode==='editor'?'Vorschau · Einzelbilder':n.cameraReady?(n.c.cameraMode==='snapshots'?'Livebilder · alle 2 Sekunden':'Live · MJPEG'):'Livebild wird geladen …'):(v?.reason||'Kamera nicht verfügbar');if(n.camera&&options.mode==='editor'){if(v?.image){if(n.camera.src!==v.image)n.camera.src=v.image;}else n.camera.removeAttribute('src');}}
      if(n.cameraError&&n.c.kind==='camera')text='Livebild nicht verfügbar · Kamera oder Einzelbild-Modus prüfen';
      if(n.c.kind==='weather'){weather(n,v);continue;}
      if(n.value.textContent!==text)n.value.textContent=text;
      n.card.classList.toggle('is-active',known&&(v.value==='on'||v.value===true||n.c.kind==='camera'||n.c.kind==='graph'));
      for(const control of n.controls){control.disabled=options.mode!=='viewer'||!known||inflight.has(id);if(control.tagName==='BUTTON')control.classList.toggle('active',known&&((v.value==='on'||v.value===true)===(control.dataset.on==='true')));if(control.type==='range'&&document.activeElement!==control&&v?.brightness!==undefined)control.value=v.brightness;
        if(control.classList.contains('climate-target')){control.disabled=control.disabled||!Number.isFinite(v?.minTemperature)||!Number.isFinite(v?.maxTemperature);control.min=v?.minTemperature??'';control.max=v?.maxTemperature??'';control.step=v?.temperatureStep||0.5;if(document.activeElement!==control)control.value=Number.isFinite(v?.targetTemperature)?v.targetTemperature:'';}
      }
      if(n.graph)graph(n,v);
    }
    cameraTick();
  }
  function weather(n,v){
    const labels={'clear-night':'Klare Nacht',cloudy:'Bewölkt',exceptional:'Außergewöhnliches Wetter',fog:'Nebel',hail:'Hagel',lightning:'Gewitter','lightning-rainy':'Gewitter mit Regen',partlycloudy:'Teilweise bewölkt',pouring:'Starkregen',rainy:'Regen',snowy:'Schnee','snowy-rainy':'Schneeregen',sunny:'Sonnig',windy:'Windig','windy-variant':'Windig und bewölkt'};
    const known=v?.known===true, o=n.c.weather||{}, format=x=>new Intl.NumberFormat('de-DE',{maximumFractionDigits:1}).format(x);
    const temperature=known&&Number.isFinite(v.temperature)?format(v.temperature)+(v.temperature_unit?' '+v.temperature_unit:' · Einheit fehlt'):'—';
    const condition=n.card.querySelector('.weather-condition'), details=n.card.querySelector('.weather-details');
    n.value.textContent=temperature;
    condition.hidden=o.showCondition===false&&known;
    condition.textContent=known?(labels[v.value]||String(v.value)):(v?.reason||'Wetter nicht verfügbar');
    const parts=[];
    if((o.style||'minimal')!=='minimal'){
      if(o.showHumidity!==false)parts.push('Luftfeuchtigkeit '+(known&&Number.isFinite(v.humidity)?format(v.humidity)+' %':'—'));
      if(o.showWind!==false)parts.push('Wind '+(known&&Number.isFinite(v.wind_speed)?format(v.wind_speed)+(v.wind_speed_unit?' '+v.wind_speed_unit:' · Einheit fehlt'):'—'));
    }
    details.textContent=parts.join(' · ');details.hidden=!parts.length;
  }
  function graph(n,v){
    if(!v||!Number.isFinite(v.observedAt))return;
    const key=documentModel.id+':'+n.c.id, binding=JSON.stringify(n.c.binding);let history=histories.get(key);
    if(!history||history.binding!==binding){history={binding,points:[],last:0};histories.set(key,history);}
    const at=v?.observedAt||Date.now()/1000, numeric=v?.known&&(typeof v.value==='number'||typeof v.value==='string')&&String(v.value).trim()!==''?Number(v.value):NaN;
    if(at>history.last+.5){history.points.push({at,value:Number.isFinite(numeric)?numeric:null});if(history.points.length>120)history.points.shift();history.last=at;}
    const points=history.points,valid=points.filter(p=>p.value!==null);if(!valid.length){n.graph.removeAttribute('d');n.card.querySelector('.chart-caption').textContent='Warte auf Zahlenwerte · unbekannte Werte sind Lücken';return;}
    let min=Math.min(...valid.map(p=>p.value)),max=Math.max(...valid.map(p=>p.value));if(min===max){min-=1;max+=1;}
    const first=points[0].at,last=points.at(-1).at;let d='',pen=false;
    for(const p of points){if(p.value===null){pen=false;continue;}const x=4+(p.at-first)/Math.max(last-first,1)*312,y=96-(p.value-min)/(max-min)*92;d+=(pen?' L':' M')+x.toFixed(2)+' '+y.toFixed(2);pen=true;}
    if(valid.length===1)d+=' l.1 0';
    if(n.graph.getAttribute('d')!==d){n.graph.getAnimations().forEach(a=>a.cancel());n.graph.setAttribute('d',d);if(n.c.animated&&Number.isFinite(numeric)&&n.lastNumber!==undefined&&n.lastNumber!==numeric&&!reduceMotion.matches&&!document.hidden)n.graph.animate([{opacity:.45},{opacity:1}],{duration:200});}
    n.lastNumber=numeric;
    n.card.querySelector('.chart-caption').textContent=`${valid.length} Messpunkte · ${Math.round(last-first)} s · Min ${Math.min(...valid.map(p=>p.value)).toLocaleString('de-DE',{maximumFractionDigits:1})} / Max ${Math.max(...valid.map(p=>p.value)).toLocaleString('de-DE',{maximumFractionDigits:1})}`;
    n.graph.parentElement.setAttribute('aria-label',n.c.title+': Minimum '+Math.min(...valid.map(p=>p.value))+', Maximum '+Math.max(...valid.map(p=>p.value)));
    // Switching between dashboards cannot grow the history indefinitely.
    while(histories.size>200)histories.delete(histories.keys().next().value);
  }
  function stopCameras(){for(const n of nodes.values())if(n.camera){n.camera.onerror=null;n.camera.onload=null;n.camera.removeAttribute('src');n.cameraAt=0;}}
  function cameraTick(){
    if(options.mode!=='viewer')return;let active=0;
    for(const [id,n] of nodes){if(!n.camera)continue;const rect=n.card.getBoundingClientRect(),visible=!document.hidden&&rect.bottom>0&&rect.top<innerHeight&&values[id]?.known&&!pausedCameras.has(id)&&active<4;
      const button=n.card.querySelector('.camera-pause');button.textContent=pausedCameras.has(id)?'Livebild fortsetzen':'Livebild pausieren';
      if(!visible){n.camera.removeAttribute('src');n.cameraAt=0;continue;}active++;
      if(!n.cameraReady&&n.camera.naturalWidth>0){n.cameraReady=true;n.cameraError=false;n.camera.classList.remove('camera-unavailable');applyValues();}
      const now=Date.now(),interval=n.c.cameraMode==='snapshots'?2000:46000;
      if(now-n.cameraAt<interval)continue;
      n.cameraAt=now;n.camera.onload=()=>{n.cameraReady=true;n.cameraError=false;n.camera.classList.remove('camera-unavailable');applyValues();};n.camera.onerror=()=>{n.cameraReady=false;n.cameraError=true;n.camera.classList.add('camera-unavailable');n.value.textContent='Livebild nicht verfügbar · Kamera oder Einzelbild-Modus prüfen';n.cameraAt=Date.now()+10000-interval;};
      n.camera.src=new URL(`api/published/${published.id}/camera/${id}?revision=${encodeURIComponent(published.revision)}&t=${now}`,location.href).href;
    }
  }
  async function request(path,body){const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),10000);try{const r=await fetch(new URL(path,location.href),{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json','X-Nodivra-CSRF':options.csrf}:{},body:body?JSON.stringify(body):undefined,cache:'no-store',signal:controller.signal});const d=await r.json();if(!r.ok)throw Error(d.error||'Anfrage nicht bestätigt.');return d;}finally{clearTimeout(timeout);}}
  async function act(c,command){if(options.mode!=='viewer'||inflight.has(c.id)||!values[c.id]?.known)return;inflight.add(c.id);applyValues();const n=nodes.get(c.id);n.feedback.textContent='Aufruf wird gesendet …';try{const result=await request('api/published/'+published.id+'/actions',{componentID:c.id,revision:published.revision,requestID:crypto.randomUUID(),...command});n.feedback.textContent=result.message;}catch(e){n.feedback.textContent=e.name==='AbortError'?'Antwort ausstehend. Gerätezustand prüfen; nicht automatisch wiederholt.':e.message;}finally{inflight.delete(c.id);applyValues();}}
  async function refresh(){if(loading||document.hidden||!published)return;loading=true;const epoch=sequence;try{const result=await request('api/published/'+published.id+'/values');if(epoch!==sequence)return;if(result.revision!==published.revision){await loadPublished(published.id);return;}values=result.values;applyValues();root.querySelector('.dash-status').textContent=result.connected?'Mit Home Assistant verbunden':'Home Assistant nicht verbunden';}catch(e){values={};applyValues();const status=root.querySelector('.dash-status');if(status)status.textContent='Verbindung unterbrochen · Bedienung pausiert';}finally{loading=false;}}
  async function loadPublished(id){sequence++;published=await request('api/published/'+encodeURIComponent(id));documentModel=published.document;values={};render();}
  async function viewer(){const id=new URL(location.href).searchParams.get('dashboard');try{if(id){await loadPublished(id);await refresh();timer=setInterval(refresh,1000);cameraTimer=setInterval(cameraTick,1000);}else{const list=await request('api/published');root.replaceChildren();root.append(el('h1','','Dashboards'),el('p','dash-catalog-subtitle','Dein Zuhause. So wie du es gestaltet hast.'));const catalog=el('div','dash-catalog');catalog.style.marginTop='24px';for(const d of list.dashboards){const a=el('a','',d.title);a.href='?dashboard='+encodeURIComponent(d.id);a.append(el('small','',d.pages+' Seiten'));catalog.append(a);}root.append(catalog);if(!list.dashboards.length)root.append(el('p','dash-status','Noch kein Dashboard veröffentlicht. Gestalte dein erstes Dashboard in der Nodivra Mac-App.'));}}catch(e){root.replaceChildren(el('p','dash-status',e.message));}}
  window.Nodivra={boot(o){options=o;if(o.mode==='viewer')viewer();else bridge({type:'ready'});},update(p){const modelChanged=!!p.document&&JSON.stringify(p.document)!==signature;if(p.document)signature=JSON.stringify(p.document);const layoutChanged=p.pageID!==payload.pageID||p.viewport!==payload.viewport||p.preview!==payload.preview;payload={...payload,...p};selected=payload.selection||'';values=payload.values||{};pageID=payload.pageID||pageID;documentModel=payload.document;if(modelChanged||layoutChanged){render();}else{markSelection();applyValues();}}};
  let lastViewport='';new ResizeObserver(()=>{if(options.mode==='viewer'&&documentModel){const v=viewport();if(v!==lastViewport){lastViewport=v;render();}}}).observe(root);
  document.addEventListener('visibilitychange',()=>{if(document.hidden)stopCameras();else{cameraTick();refresh();}});
  window.addEventListener('pagehide',()=>{clearInterval(timer);clearInterval(cameraTimer);stopCameras();sequence++;});
})();
