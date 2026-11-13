# make_icon.py: Plugin Assistant icon (a rack of three slots with knobs). python3 make_icon.py
import os, subprocess, shutil
from PIL import Image, ImageDraw, ImageFont
S=1024
img=Image.new("RGBA",(S,S),(0,0,0,0))
t=Image.new("L",(S,S),0); ImageDraw.Draw(t).rounded_rectangle((100,100,924,924),radius=185,fill=255)
img.paste(Image.new("RGBA",(S,S),(22,18,14,255)),(0,0),t)
d=ImageDraw.Draw(img)
for i,y in enumerate((200,380,560)):
    d.rounded_rectangle((200,y,824,y+140),radius=24,fill=(60,52,44,255),outline=(196,140,80,255),width=6)
    d.ellipse((240,y+30,320,y+110),fill=(236,214,176,255))
    d.rounded_rectangle((380,y+60,780,y+80),radius=10,fill=(196,140,80,255) if i!=1 else (90,80,70,255))
F="/System/Library/Fonts/SFNSRounded.ttf"
if not os.path.exists(F): F="/System/Library/Fonts/Helvetica.ttc"
d.text((S/2,820),"PLUGIN",font=ImageFont.truetype(F,110),fill=(236,214,176,255),anchor="mm")
img.save("icon_1024.png")
os.makedirs("AppIcon.iconset",exist_ok=True)
for s in (16,32,128,256,512):
    img.resize((s,s),Image.LANCZOS).save(f"AppIcon.iconset/icon_{s}x{s}.png")
    img.resize((s*2,s*2),Image.LANCZOS).save(f"AppIcon.iconset/icon_{s}x{s}@2x.png")
subprocess.run(["iconutil","-c","icns","AppIcon.iconset","-o","AppIcon.icns"],check=True)
shutil.rmtree("AppIcon.iconset")
for s in (16,48,128): img.resize((s,s),Image.LANCZOS).save(f"../extension/icon{s}.png")
