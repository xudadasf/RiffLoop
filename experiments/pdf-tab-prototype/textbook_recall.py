"""Broad staff proposals for manual review, independent of OCR bar detection."""
import cv2
import numpy as np

from raster_tab import ink_mask, runs


def staff_proposals(gray):
    height, width = gray.shape
    horizontal = cv2.morphologyEx(ink_mask(gray), cv2.MORPH_OPEN,
                                np.ones((1, max(20, width//60)), np.uint8))
    proposals = []
    for left, right in [(0,width), (0,width//2), (width//2,width)]:
        span = right-left
        coverage = (horizontal[:,left:right]>0).sum(axis=1)
        starts = np.flatnonzero(coverage > max(60,span*.22))
        if not len(starts):
            continue
        gaps = np.arange(5, min(45,height/15), .5)
        for count in (6,5):
            targets = np.rint(starts[:,None,None] + gaps[None,:,None]*np.arange(count)).astype(int)
            valid_height = targets[:,:,-1] < height-2
            targets = np.clip(targets,1,height-2)
            values = np.maximum.reduce([coverage[targets+i] for i in (-1,0,1)])
            valid = valid_height & (values.min(axis=2)>max(60,span*.22)) & (values.mean(axis=2)>span*.38)
            ranked = [(float(values[a,b].mean()), targets[a,b], float(gaps[b])) for a,b in zip(*np.where(valid))]
            used = []
            for strength, ys, gap in sorted(ranked,key=lambda x:-x[0]):
                if any(abs(int(ys[0])-y)<gap*3 for y in used):
                    continue
                support = sum((horizontal[y-1:y+2,left:right]>0).any(axis=0).astype(np.uint8) for y in ys)
                mask = (support>=count-2).astype(np.uint8).reshape(1,-1)
                mask = cv2.morphologyEx(mask,cv2.MORPH_CLOSE,np.ones((1,max(5,round(gap*2))),np.uint8)).ravel()
                spans = [g for g in runs(np.flatnonzero(mask)) if len(g)>max(100,gap*12)]
                for xs in spans:
                    x0,x1 = left+xs[0],left+xs[-1]
                    if any(abs(ys[0]-p['core'][1])<gap*3 and min(x1,p['core'][2])-max(x0,p['core'][0]) > min(x1-x0,p['core'][2]-p['core'][0])*.7 for p in proposals):
                        continue
                    core = [int(x0),int(ys[0]),int(x1),int(ys[-1])]
                    box = [max(0,round(x0-2*gap)),max(0,round(ys[0]-(18 if count==6 else 8)*gap)),
                           min(width,round(x1+2*gap)),min(height,round(ys[-1]+(6 if count==6 else 24)*gap))]
                    proposals.append({'core':core,'box':box,'gap':gap,'lines':count})
                used.append(int(ys[0]))
    return proposals


def add_recall_candidates(gray, regions):
    """Keep existing decisions; expose missed/partial staves as editable candidates."""
    proposals = staff_proposals(gray)
    # Six-line proposals usually include both staves; five-line fallback covers
    # rows whose TAB was obscured by digits or thick beams.
    for proposal in sorted(proposals,key=lambda p:-p['lines']):
        core,box = proposal['core'],proposal['box']
        area = max(1,(core[2]-core[0])*(core[3]-core[1]))
        def covered(r):
            a=r['box']
            return max(0,min(a[2],core[2])-max(a[0],core[0]))*max(0,min(a[3],core[3])-max(a[1],core[1]))/area
        if any(covered(r)>.85 for r in regions):
            continue
        partial = next((r for r in regions if not r['accepted'] and covered(r)>.2),None)
        if partial:
            a=partial['box']
            partial['box']=[min(a[0],box[0]),min(a[1],box[1]),max(a[2],box[2]),max(a[3],box[3])]
            partial['reason']='补全疑似谱行范围，需人工确定边界与采用状态'
            partial['recall_candidate']=True
        else:
            regions.append({'box':box,'accepted':False,'systems':1,'gap':proposal['gap'],
                            'recall_candidate':True,'reason':'补充谱线候选；需人工确定是否乐谱及完整边界'})
    def overlap(a,b):
        return max(0,min(a[2],b[2])-max(a[0],b[0]))*max(0,min(a[3],b[3])-max(a[1],b[1]))
    def area(a):
        return max(1,(a[2]-a[0])*(a[3]-a[1]))
    regions=[r for r in regions if r['accepted'] or not any(
        other['accepted'] and overlap(r['box'],other['box'])/area(r['box'])>.95 for other in regions)]
    merged=[]
    for r in sorted(regions,key=lambda r:(r['box'][1],r['box'][0])):
        b=r['box']
        previous=next((p for p in reversed(merged) if not p['accepted'] and not r['accepted']
            and min(p['box'][2]-p['box'][0],b[2]-b[0])/max(p['box'][2]-p['box'][0],b[2]-b[0])>.75
            and overlap(p['box'],b)/min(area(p['box']),area(b))>.15),None)
        if previous:
            a=previous['box'];previous['box']=[min(a[0],b[0]),min(a[1],b[1]),max(a[2],b[2]),max(a[3],b[3])]
            previous['reason']='合并重叠候选以保留完整范围；请人工确定'
        else:merged.append(r)
    return merged
