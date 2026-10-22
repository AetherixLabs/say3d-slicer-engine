import struct, sys
def box(x0,y0,z0,x1,y1,z1):
    v=[(x0,y0,z0),(x1,y0,z0),(x1,y1,z0),(x0,y1,z0),(x0,y0,z1),(x1,y0,z1),(x1,y1,z1),(x0,y1,z1)]
    f=[(0,2,1),(0,3,2),(4,5,6),(4,6,7),(0,1,5),(0,5,4),(1,2,6),(1,6,5),(2,3,7),(2,7,6),(3,0,4),(3,4,7)]
    return [(v[a],v[b],v[c]) for a,b,c in f]
def write(path,tris):
    with open(path,'wb') as o:
        o.write(b'\0'*80); o.write(struct.pack('<I',len(tris)))
        for t in tris:
            o.write(struct.pack('<3f',0,0,0))
            for p in t: o.write(struct.pack('<3f',*p))
            o.write(b'\0\0')
write('cube20.stl', box(0,0,0,20,20,20))
# A "T": a 10x10x30 post with a 50x10x5 bar on top: 20 mm overhangs both sides.
# Two touching boxes (non-manifold seam is fine for Orca's repair) -> make one closed solid instead:
def tshape():
    # stem 20..30 x, 0..10 y, 0..30 z ; bar 0..50 x, 0..10 y, 30..35 z — build as union via polygon extrusion in XZ.
    poly=[(20,0),(30,0),(30,30),(50,30),(50,35),(30,35),(20,35),(0,35),(0,30),(20,30)]  # XZ outline, CCW seen from -Y
    y0,y1=0,10; tris=[]
    n=len(poly)
    for i in range(n):
        a=poly[i]; b=poly[(i+1)%n]
        A0=(a[0],y0,a[1]);B0=(b[0],y0,b[1]);A1=(a[0],y1,a[1]);B1=(b[0],y1,b[1])
        tris.append((A0,B0,B1)); tris.append((A0,B1,A1))
    # caps: triangulate the outline manually (convex parts): stem rect + bar rect
    def cap(rect,y,flip):
        (x0,z0),(x1,z1)=rect
        p=[(x0,y,z0),(x1,y,z0),(x1,y,z1),(x0,y,z1)]
        t=[(p[0],p[1],p[2]),(p[0],p[2],p[3])]
        return [(c,b,a) for a,b,c in t] if flip else t
    for rect in [((20,0),(30,30)),((0,30),(20,35)),((20,30),(30,35)),((30,30),(50,35))]:
        tris+=cap(rect,y0,True); tris+=cap(rect,y1,False)
    return tris
write('tshape.stl', [(c,b,a) for a,b,c in tshape()])
