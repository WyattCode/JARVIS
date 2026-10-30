from pathlib import Path
import math,json
root=Path(__file__).parent
WHITE='#ECF8FC';BLUE='#8FDCEB'
def pt(r,a):
 t=math.radians(a);return [54+r*math.cos(t),54+r*math.sin(t)]
def circle(r,w=1.8,c=WHITE):return dict(type='circle',r=r,width=w,color=c)
def radial(r1,r2,a,w=2,c=WHITE,offset=0):
 x1,y1=pt(r1,a);x2,y2=pt(r2,a);t=math.radians(a);dx=-math.sin(t)*offset;dy=math.cos(t)*offset
 return dict(type='line',x1=x1+dx,y1=y1+dy,x2=x2+dx,y2=y2+dy,width=w,color=c)
def arc(r,start,end,w=2,c=WHITE):return dict(type='arc',r=r,start=start,end=end,width=w,color=c)
def polygon(points,w=1.9,c=WHITE):return dict(type='polygon',points=points,width=w,color=c)
def d_triangles(w=1.9):return [polygon([[35.5,43.3],[72.5,43.3],[54,75.3]],w),polygon([[46,49.4],[62,49.4],[54,63.3]],2.0,BLUE)]
def d_braces(w=2.0):return [radial(21.35,26.2,a,w) for a in [210,330,90]]
def a_braces(w=1.7):return [radial(10.9,16.4,-90+i*120,w) for i in range(3)]
variants={
 'D-A':{'family':'D','variant':'A','name':'纯净三角','description':'保留圆框、双层倒三角和三向支撑，去掉外圈刻度。','parts':[circle(27,1.8)]+d_triangles(2.0)+d_braces(2.0)},
 'D-B':{'family':'D','variant':'B','name':'精密线圈','description':'保留十处分区，加入一层内环，加强反应堆的结构层次。','parts':[circle(27,1.6),circle(21.6,1.25)]+[radial(22.5,25.5,-90+i*36,1.8) for i in range(10)]+d_triangles(1.8)+d_braces(1.8)},
 'D-C':{'family':'D','variant':'C','name':'开环脉冲','description':'外圈改为三段开环，保留双层倒三角和三向支撑。','parts':[arc(27,a-54,a+54,2.1) for a in [210,330,90]]+d_triangles(2.0)+d_braces(1.95)},
 'A-A':{'family':'A','variant':'A','name':'纯净环核','description':'保留同心环与三向内支架，减少外圈细节。','parts':[circle(27,1.8),circle(18.8,1.7),circle(8.8,2.1,BLUE)]+a_braces(1.8)},
 'A-B':{'family':'A','variant':'B','name':'双线线圈','description':'外圈十组刻度改成双线线圈，保留圆形核心和内支架。','parts':[circle(27,1.6),circle(18.8,1.5),circle(8.8,2.0,BLUE)]+[radial(21,25.4,-90+i*36,1.35,offset=offset) for i in range(10) for offset in [-1.5,1.5]]+a_braces(1.65)},
 'A-C':{'family':'A','variant':'C','name':'脉冲环核','description':'外圈改为三段开环与六处短刻度，中心结构保持圆形。','parts':[arc(27,-90+i*120-49,-90+i*120+49,2.05) for i in range(3)]+[circle(18.8,1.65),circle(8.8,2.0,BLUE)]+[radial(22,25,-90+i*60,1.9) for i in range(6)]+a_braces(1.75)}
}
def element(v):
 attrs=f'fill="none" stroke="{v["color"]}" stroke-width="{v["width"]}" stroke-linecap="round"'
 if v['type']=='circle':return f'<circle cx="54" cy="54" r="{v["r"]}" {attrs}/>'
 if v['type']=='line':return f'<line x1="{v["x1"]:.4f}" y1="{v["y1"]:.4f}" x2="{v["x2"]:.4f}" y2="{v["y2"]:.4f}" {attrs}/>'
 if v['type']=='polygon':
  points=' '.join(f'{x:.4f},{y:.4f}' for x,y in v['points']);return f'<polygon points="{points}" stroke-linejoin="round" {attrs}/>'
 x1,y1=pt(v['r'],v['start']);x2,y2=pt(v['r'],v['end']);large=int(v['end']-v['start']>180)
 return f'<path d="M{x1:.4f},{y1:.4f} A{v["r"]},{v["r"]} 0 {large} 1 {x2:.4f},{y2:.4f}" {attrs}/>'
for key,data in variants.items():
 shapes='\n'.join(element(x) for x in data['parts'])
 (root/f'reactor-{key}.svg').write_text(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="18 18 72 72" role="img" aria-label="{key} {data["name"]}"><rect x="18" y="18" width="72" height="72" fill="#000000"/>{shapes}</svg>\n')
 (root/f'reactor-{key}-foreground.svg').write_text(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">{shapes}</svg>\n')
(root/'schemes.json').write_text(json.dumps(variants,ensure_ascii=False,indent=2)+'\n')
