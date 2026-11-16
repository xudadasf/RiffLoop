"""Local numeric reference for the native TAB geometry path, not an app backend.

Explicit --image only; never uploads input. Native simulator tests use synthetic
images. Results here are desktop evidence, not a native-device accuracy claim.
"""
import argparse
import json
import math
import numpy as np
import cv2
from PIL import Image, ImageOps
import onnxruntime as ort

def groups(values):
    out=[]
    for value in values:
        value=int(value)
        if out and value==out[-1][-1]+1: out[-1].append(value)
        else: out.append([value])
    return out

def mask(gray):
    h,w=gray.shape
    integral=np.pad(gray.astype(np.int64),((1,0),(1,0))).cumsum(0).cumsum(1)
    y,x=np.mgrid[:h,:w];t=np.maximum(0,y-20);b=np.minimum(h,y+21);l=np.maximum(0,x-20);r=np.minimum(w,x+21)
    mean=(integral[b,r]-integral[t,r]-integral[b,l]+integral[t,l])//((b-t)*(r-l))
    return gray<mean-12

def deskew(gray):
    h,w=gray.shape; ink=mask(gray); y,x=np.nonzero(ink[:,::max(2,w//600)]);x=x*max(2,w//600)
    def score(angle):
        rows=np.floor(y-np.tan(angle*np.pi/180)*(x-w//2)+.5).astype(int)+w//5+2
        bins=np.bincount(rows,minlength=h+(w//5+2)*2)
        return float((bins*bins).sum())
    base=score(0);angle=max(np.arange(-8,8.001,.25),key=score);angle=max([angle]+[angle+step/40 for step in range(-10,11)],key=score)
    if abs(angle)<.2 or score(angle)<=base*1.12:return gray,0
    c=np.cos(angle*np.pi/180);s=np.sin(angle*np.pi/180);ww=math.ceil(w*c+h*abs(s));hh=math.ceil(h*c+w*abs(s));yy,xx=np.mgrid[:hh,:ww]
    dx=xx-ww/2;dy=yy-hh/2;sx=c*dx-s*dy+w/2;sy=s*dx+c*dy+h/2;ix=np.floor(sx).astype(int);iy=np.floor(sy).astype(int);fx=sx-ix;fy=sy-iy
    valid=(ix>=0)&(ix+1<w)&(iy>=0)&(iy+1<h);out=np.full(yy.shape,255,np.uint8);x=ix[valid];y=iy[valid];f=fx[valid];g=fy[valid]
    top=gray[y,x]*(1-f)+gray[y,x+1]*f;bottom=gray[y+1,x]*(1-f)+gray[y+1,x+1]*f;out[valid]=np.floor(top*(1-g)+bottom*g+.5).astype(np.uint8)
    return out,float(angle)

def systems(gray):
    h,w=gray.shape;ink=mask(gray);horizontal=np.zeros_like(ink)
    for y in range(h):
        for run in groups(np.flatnonzero(ink[y])):
            if len(run)>=max(12,w//60):horizontal[y,run]=True
    coverage=horizontal.sum(1); rows=[]
    for group in groups(np.flatnonzero(coverage>max(40,w//6))):
        best=[y for y in group if coverage[y]==max(coverage[group])];rows.append(sum(best)//len(best))
    used=set();found=[]
    for start in range(len(rows)-5):
        ys=rows[start:start+6];gap=(ys[-1]-ys[0])/5
        if not 4<=gap<=90 or used.intersection(ys) or max(abs(np.diff(ys)-gap))>max(2,gap*.18):continue
        support=sum(horizontal[max(0,y-3):min(h,y+4)].any(0).astype(int) for y in ys)
        xs=np.flatnonzero(support>=4)
        if not len(xs):continue
        left,right=int(xs[0]),int(xs[-1])
        if right-left<max(70,int(gap*8)) or any(horizontal[max(0,y-2):min(h,y+3),left:right+1].any(0).sum()<=(right-left)//2 for y in ys):continue
        neighbors=[y for y in rows if abs(y-ys[0]+gap)<gap*.18 or abs(y-ys[-1]-gap)<gap*.18]
        if any(horizontal[y,left:right+1].sum()>(right-left)//2 for y in neighbors):continue
        if any(len(g)>gap*6 for g in groups(np.flatnonzero(support[left:right+1]<2))):continue
        vertical=np.flatnonzero(ink[ys[0]:ys[-1]+1,left:right+1].mean(0)>.88)+left
        boundaries=[left]
        for group in groups(vertical):
            x=sum(group)//len(group)
            if x-left<=gap*1.5 or right-x<=gap*.8:continue
            bottom=min(h-1,ys[-1]+int(gap*1.7));top=min(bottom,ys[-1]+max(1,int(gap*.3)))
            if ink[top:bottom+1,max(0,x-1):min(w,x+2)].any(1).mean()>=.45:continue
            centers=[];radius=max(2,round(gap*.25))
            for y0,y1 in zip(ys,ys[1:]):
                occupied=np.flatnonzero(ink[math.floor((y0+y1)/2+.5),max(0,x-radius):min(w,x+radius+1)])
                if len(occupied):centers.append(float(occupied.mean()))
            straight=(ink[ys[0]:ys[-1]+1,max(0,x-1):min(w,x+2)].mean(0)>=.98).sum()>=2
            if len(centers)!=5 or not(straight or max(centers)-min(centers)<=max(1.2,gap*.08)):continue
            if x-boundaries[-1]>gap*.8:boundaries.append(x)
        boundaries.append(right);found.append(dict(rows=ys,left=left,right=right,boundaries=boundaries,gap=gap));used.update(ys)
    return found

def decode(gray,gap,session):
    h,w=gray.shape;sourcew=w
    if max(w,h)>2000:
        ratio=2000/max(w,h);w=round(int(w*ratio)/32)*32;h=round(int(h*ratio)/32)*32;gray=cv2.resize(gray,(w,h))
    if min(w,h)<30:
        ratio=30/min(w,h);w=round(int(w*ratio)/32)*32;h=round(int(h*ratio)/32)*32;gray=cv2.resize(gray,(w,h))
    ratio=w/h;width=int(48*max(320/48,ratio));effective=min(width,math.ceil(48*ratio))
    image=cv2.resize(gray,(effective,48));tensor=np.zeros((1,3,48,width),np.float32);tensor[:,:,:,:effective]=(image.astype(np.float32)/255-.5)/.5
    output=session.run(None,{'x':tensor})[0][0];ids=output.argmax(1);scores=output.max(1);length=len(ids)*ratio/max(320/48,ratio)
    chars=[];previous=-1
    for t,value in enumerate(ids):
        if value!=0 and value!=previous:chars.append(dict(char=str(value-33) if 33<=value<=42 else None,x=t*sourcew/length,score=float(scores[t])))
        previous=value
    grouped=[];may_join=False
    for char in chars:
        if char['char'] is None or not 0<=char['x']<sourcew:may_join=False;continue
        if may_join and char['x']-grouped[-1][-1]['x']<=gap*.95:grouped[-1].append(char)
        else:grouped.append([char])
        may_join=True
    def fret(g):
        value=''.join(c['char'] for c in g)
        return int(value) if 1<=len(value)<=2 and (len(value)==1 or value[0]!='0') and int(value)<=36 else None
    split=[]
    for g in grouped:
        if len(g)>2:
            distances=np.diff([c['x'] for c in g]);cuts=[i+1 for i,d in enumerate(distances) if d>=max(gap*.7,np.median(distances)*1.3)]
            pieces=[g[a:b] for a,b in zip([0]+cuts,cuts+[len(g)])]
            if cuts and all(fret(p) is not None for p in pieces):split.extend(pieces);continue
        split.append(g)
    return [dict(x=sum(c['x'] for c in g)/len(g),fret=fret(g),score=min(c['score'] for c in g)) for g in split]

def transcribe(gray,session):
    gray,angle=deskew(gray);found=systems(gray);bars=[];h,w=gray.shape;ink=mask(gray)
    for system in found:
        gap=system['gap']
        for a,b in zip(system['boundaries'],system['boundaries'][1:]):
            notes=[]
            def band(left,right,center,gap):
                t=max(0,round(center-gap*.45));bottom=min(h,round(center+gap*.45)+1);im=gray[t:bottom,left:right]
                rows=np.arange(bottom-t);coverage=ink[t:bottom,left:right][np.abs(rows-(center-t))>max(2,int(gap*.16))].sum(0)
                content=[g for g in groups(np.flatnonzero(coverage>=max(2,int(gap*.18)))) if len(g)>=max(3,int(gap*.2))]
                if not content:return None
                x0=max(0,content[0][0]-max(2,int(gap*.35)));x1=min(right-left,content[-1][-1]+max(3,int(gap*.35))+1)
                im=im[:,x0:x1];ordered=np.sort(im.ravel());low=int(ordered[len(ordered)//50]);high=int(ordered[len(ordered)*95//100])
                if high<215 and high-low>15:im=np.clip((im.astype(np.int32)-low)*255//(high-low),0,255).astype(np.uint8)
                return im,left+x0
            local=[]
            for row in system['rows']:
                radius=max(2,int(gap*.25));rr=list(range(max(0,row-radius),min(h-1,row+radius)+1));coverage=[int(ink[y,a:b].sum()) for y in rr];best=[y for y,c in zip(rr,coverage) if c==max(coverage)];local.append(sum(best)//len(best))
            for i,y in enumerate(local):
                left=a+max(2,int(gap*.18));right=b-1;image=band(left,right,y,gap)
                if image is None:continue
                digits=decode(image[0],gap,session)
                for d in digits:d['x']+=image[1]
                if not digits or any(d['score']<.9 for d in digits):
                    for shift in [-1,1]:
                        retry=band(left,right,y+shift*max(1,math.floor(gap*.15+.5)),gap)
                        if retry is None:continue
                        other=decode(retry[0],gap,session)
                        for d in other:d['x']+=retry[1]
                        old=sum(d['score'] for d in digits)/max(1,len(digits));new=sum(d['score'] for d in other)/max(1,len(other))
                        if other and new>old+.1 and (not digits or len(other)==len(digits)):digits=other
                        for candidate in other:
                            if candidate['score']<.9 or candidate['fret'] is None:continue
                            matches=[j for j,d in enumerate(digits) if abs(d['x']-candidate['x'])<gap*.65]
                            if matches:
                                j=matches[0]
                                if candidate['score']>digits[j]['score']+.08:digits[j]=candidate
                            elif candidate['score']>=.95:digits.append(candidate)
                if image[0].shape[1]>max(96,int(gap*12)) or any(d['score']<.65 for d in digits):
                    im,offset=image;size=max(96,int(gap*12));step=max(1,size-int(gap*3))
                    for start in range(0,im.shape[1],step):
                        end=min(im.shape[1],start+size)
                        if end-start<gap*2:continue
                        for other in decode(im[:,start:end],gap,session):
                            if other['score']<.9 or other['fret'] is None:continue
                            if start>0 and other['x']<gap*.7 or end<im.shape[1] and other['x']>end-start-gap*.7:continue
                            other['x']+=offset+start
                            matches=[j for j,d in enumerate(digits) if abs(d['x']-other['x'])<gap*.65]
                            if matches:
                                j=matches[0]
                                if other['score']>digits[j]['score']+.08:digits[j]=other
                            else:digits.append(other)
                if any(d['score']>=.85 for d in digits):
                    known=[d['x'] for d in digits if d['score']>=.85]
                    half=int(gap*.45);margin=max(2,int(gap*.16));rr=np.arange(max(0,y-half),min(h-1,y+half)+1);cov=ink[rr[np.abs(rr-y)>margin],left:right].sum(0);spans=[]
                    for g in groups(np.flatnonzero(cov>=2)+left):
                        if spans and g[0]-spans[-1][-1]<=gap*.6:spans[-1]=list(range(spans[-1][0],g[-1]+1))
                        else:spans.append(g)
                    for span in spans:
                        if not max(3,int(gap*.25))<=span[-1]-span[0]+1<=gap*2.2:continue
                        center=(span[0]+span[-1])/2;matches=[j for j,d in enumerate(digits) if abs(d['x']-center)<gap*.8]
                        if matches and digits[matches[0]]['score']>=.9:continue
                        if not matches and not min(known)<center<max(known):continue
                        votes={}
                        for pad in set([max(3,int(gap*.3)),max(3,int(gap*.75))]):
                            for shift in [-2,0,2]:
                                crop=gray[max(0,y+shift-math.floor(gap*.5+.5)):min(h,y+shift+math.floor(gap*.5+.5)+1),max(0,span[0]-pad):min(w,span[-1]+pad+1)]
                                isolated=decode(crop,gap,session)
                                if len(isolated)!=1 or isolated[0]['score']<.5 or isolated[0]['fret'] is None:continue
                                votes.setdefault(isolated[0]['fret'],[]).append(isolated[0])
                        agreeing=[v for v in votes.values() if len(v)>=2 and max(d['score'] for d in v)>=.9]
                        if len(agreeing)!=1:continue
                        value=max(agreeing[0],key=lambda d:d['score']);value['x']=center;matches=[j for j,d in enumerate(digits) if abs(d['x']-center)<gap*.8]
                        if matches:
                            j=matches[0]
                            if value['score']>digits[j]['score']+.08:digits[j]=value
                        elif value['score']>=.95:digits.append(value)
                def stem(d):
                    if d['fret']!=1:return False
                    radius=max(2,int(gap*.25));x=int(d['x']);top=max(0,y-int(gap*.85));bottom=min(h-1,y+int(gap*.85))
                    rr=max(3,int(gap*.4));margin=max(2,int(gap*.16));half=max(margin+1,int(gap*.45));above=ink[max(0,y-half):max(0,y-margin)+1,max(0,x-rr):min(w,x+rr+1)].sum();below=ink[min(h-1,y+margin):min(h-1,y+half)+1,max(0,x-rr):min(w,x+rr+1)].sum()
                    if min(above,below)<max(4,int(gap*.25)):return True
                    return (ink[top:bottom+1,max(0,x-radius):min(w,x+radius+1)].mean(0)>=.88).any()
                notes.extend(dict(string=i+1,x=d['x'],fret=d['fret'],score=round(d['score'],3)) for d in digits if d['score']>=.5 and not stem(d) and min(d['x']-a,b-d['x'])>=gap*.75)
            notes=[n for n in notes if not(n['score']<.85 and any(abs(other['string']-n['string'])==1 and other['score']>=.9 and abs(other['x']-n['x'])<gap*.65 for other in notes))]
            bars.append(sorted(notes,key=lambda n:n['x']))
    return dict(angle=angle,systems=found,bars=bars)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--image',required=True);parser.add_argument('--model',required=True);args=parser.parse_args()
    image=np.asarray(ImageOps.exif_transpose(Image.open(args.image)).convert('L'))
    options=ort.SessionOptions();options.intra_op_num_threads=1
    session=ort.InferenceSession(args.model,sess_options=options,providers=['CPUExecutionProvider'])
    print(json.dumps(transcribe(image,session),ensure_ascii=False))
