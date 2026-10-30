from pathlib import Path
import math,json
root=Path(__file__).parent
WHITE='#ECF8FC';BLUE='#8FDCEB'
def p(r,a):
 t=math.radians(a);return (54+r*math.cos(t),54+r*math.sin(t))
def circle(r,w=1.8,c=WHITE):return dict(type='circle',r=r,width=w,color=c)
def radial(r1,r2,a,w=2.2,c=WHITE):
 x1,y1=p(r1,a);x2,y2=p(r2,a)
 return dict(type='line',x1=x1,y1=y1,x2=x2,y2=y2,width=w,color=c)
def arc(r,start,end,w=2.1,c=WHITE):return dict(type='arc',r=r,start=start,end=end,width=w,color=c)
schemes={
 'A':{'name':'原型环核','description':'十处外圈分区与三向内支架，保留圆形反应堆的主要结构。','parts':[circle(27,1.7),circle(18.8,1.5),circle(8.8,2.0,BLUE)]+[radial(21,25.4,-90+i*36,2.4) for i in range(10)]+[radial(10.9,16.4,-90+i*120,1.7) for i in range(3)]},
 'B':{'name':'放射分区','description':'外圈拆成八段，放射线连接内外环，中心保留空心核心。','parts':[arc(27,-90+i*45-17.5,-90+i*45+17.5,2.15) for i in range(8)]+[circle(18.5,1.6),circle(8.2,2.0,BLUE)]+[radial(19,26.4,-90+i*45,1.9) for i in range(8)]},
 'C':{'name':'极简环核','description':'三段外环、三处短连接线与双层核心，进一步减少机械细节。','parts':[arc(27,-90+i*120-47,-90+i*120+47,2.2) for i in range(3)]+[circle(17.3,1.65),circle(7.5,2.1,BLUE)]+[radial(20.5,24.2,-90+i*120,2.1) for i in range(3)]}
}
schemes['D'] = {
 'name':'三角支撑',
 'description':'参照图05：圆形外框、倒三角主支撑，以及三向连接。',
 'parts':[circle(27,1.7)]+[radial(23.5,26.2,-90+i*36,2.15) for i in range(10)]+[
   dict(type='polygon',points=[[35.5,43.3],[72.5,43.3],[54,75.3]],width=1.9,color=WHITE),
   dict(type='polygon',points=[[46,49.4],[62,49.4],[54,63.3]],width=2.0,color=BLUE),
   radial(21.35,26.2,210,2.15),radial(21.35,26.2,330,2.15),radial(21.35,26.2,90,2.15)
 ]
}
def element(item):
 attrs=f'fill="none" stroke="{item["color"]}" stroke-width="{item["width"]}" stroke-linecap="round"'
 if item['type']=='polygon':
  points=' '.join(f'{x:.4f},{y:.4f}' for x,y in item['points'])
  return f'<polygon points="{points}" stroke-linejoin="round" {attrs}/>'
 if item['type']=='circle':return f'<circle cx="54" cy="54" r="{item["r"]}" {attrs}/>'
 if item['type']=='line':return f'<line x1="{item["x1"]:.4f}" y1="{item["y1"]:.4f}" x2="{item["x2"]:.4f}" y2="{item["y2"]:.4f}" {attrs}/>'
 x1,y1=p(item['r'],item['start']);x2,y2=p(item['r'],item['end']);large=int(item['end']-item['start']>180)
 return f'<path d="M{x1:.4f},{y1:.4f} A{item["r"]},{item["r"]} 0 {large} 1 {x2:.4f},{y2:.4f}" {attrs}/>'
for key,data in schemes.items():
 items='\n'.join(element(x) for x in data['parts'])
 (root/f'reactor-{key}.svg').write_text(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="18 18 72 72" role="img" aria-label="{key} {data["name"]}"><rect x="18" y="18" width="72" height="72" fill="#000000"/>{items}</svg>\n')
 (root/f'reactor-{key}-foreground.svg').write_text(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">{items}</svg>\n')
(root/'schemes.json').write_text(json.dumps(schemes,ensure_ascii=False,indent=2)+'\n')
