/* Viewer-only chrome; no access to the embedding Home Assistant DOM. */
(() => {
  const toggle=document.getElementById('navigation-toggle'), sidebar=document.getElementById('viewer-navigation'), backdrop=document.getElementById('navigation-backdrop');
  if(!toggle||!sidebar)return;
  const mobile=matchMedia('(max-width:760px)');
  const key=()=> 'nodivra-navigation-'+(mobile.matches?'mobile':'desktop');
  const saved=()=>{try{return localStorage.getItem(key());}catch{return null;}};
  let open=saved()===null?!mobile.matches:saved()==='open';
  function apply(persist=false){
    document.body.classList.toggle('navigation-collapsed',!open);document.body.classList.toggle('navigation-open',open);
    sidebar.hidden=!open;backdrop.hidden=!(open&&mobile.matches);
    toggle.setAttribute('aria-expanded',String(open));toggle.setAttribute('aria-label',open?'Navigation ausblenden':'Navigation einblenden');
    if(persist)try{localStorage.setItem(key(),open?'open':'closed');}catch{}
  }
  toggle.onclick=()=>{open=!open;apply(true);};
  const close=()=>{open=false;apply(true);toggle.focus();};
  backdrop.onclick=close;
  document.addEventListener('keydown',e=>{if(e.key==='Escape'&&open){close();}});
  sidebar.addEventListener('click',e=>{if(mobile.matches&&e.target.closest('#dashboard-page-nav button'))close();});
  mobile.addEventListener('change',()=>{open=saved()===null?!mobile.matches:saved()==='open';apply();});
  const separate=document.getElementById('open-unframed');
  if(separate&&window.self!==window.top){separate.hidden=false;separate.href=location.href;}
  apply();
})();
