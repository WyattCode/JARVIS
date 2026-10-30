/* Product family chooses the design. Window space chooses its responsive layout.
 * PC touch hardware never opts into mobile-only UI. CSS and JS use one policy.
 */
// Choose the product surface independently of optional PC touch hardware.
(()=>{
 const ua=navigator.userAgent,platform=navigator.platform||'';
 const mobile=/Android|iPhone|iPad|iPod/i.test(ua)||navigator.userAgentData?.mobile===true||(platform==='MacIntel'&&navigator.maxTouchPoints>1);
 const root=document.documentElement;
 root.dataset.uiSurface=mobile?'mobile':'desktop';
 // Product family, available layout space and input hardware are separate axes.
 function syncTraits(){
  const wide=innerWidth>=760||(innerWidth>=600&&innerHeight>=600);
  root.dataset.uiLayout=!mobile?'desktop':wide?(innerWidth>innerHeight?'tablet-landscape':'tablet-portrait'):'phone';
  const fine=window.matchMedia('(any-pointer:fine)').matches,touch=navigator.maxTouchPoints>0;
  root.dataset.uiInput=touch?(fine?'mixed':'touch'):'pointer';
 }
 syncTraits();window.addEventListener('resize',syncTraits,{passive:true});
 document.addEventListener('DOMContentLoaded',syncTraits,{once:true});
 window.matchMedia('(any-pointer:fine)').addEventListener('change',syncTraits);
 const nativeMatchMedia=window.matchMedia.bind(window);
 function surfaceQuery(query){
  return query.split(',').map(branch=>{
   branch=branch.replace(/\(\s*not\s*\(\s*any-pointer\s*:\s*coarse\s*\)\s*\)/gi,mobile?'(max-width:0px)':'(min-width:0px)');
   if(mobile)return branch.replace(/\(\s*(?:any-)?pointer\s*:\s*coarse\s*\)/gi,'(min-width:0px)').replace(/\(\s*pointer\s*:\s*fine\s*\)/gi,'(max-width:0px)');
   if(/\(\s*(?:any-)?pointer\s*:\s*coarse\s*\)|\(\s*(?:any-)?hover\s*:\s*none\s*\)/i.test(branch))return 'not all';
   return branch.replace(/\(\s*(?:any-)?pointer\s*:\s*fine\s*\)|\(\s*(?:any-)?hover\s*:\s*hover\s*\)/gi,'(min-width:0px)');
  }).join(',');
 }
 window.jarvisMatchMedia=query=>nativeMatchMedia(surfaceQuery(query));
 window.jarvisApplySurfaceStyles=()=>{
  const visit=rules=>{for(const rule of rules){if(rule.type===CSSRule.MEDIA_RULE)rule.media.mediaText=surfaceQuery(rule.media.mediaText);if(rule.cssRules&&rule.type!==CSSRule.KEYFRAMES_RULE)visit(rule.cssRules)}};
  for(const sheet of document.styleSheets){if(sheet.ownerNode?.id!=='jarvis-ui-styles')continue;try{visit(sheet.cssRules)}catch{}}
 };
})();
