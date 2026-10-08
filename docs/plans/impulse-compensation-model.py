import math
DT=1/60; W=4.74/0.15; DV=200.0; TT=1/6  # owner velocity relax tau_true 167ms (G16 toy body)
def D(s,tau):  # displacement s seconds after a dv with exp velocity decay
    if s<=0: return 0.0
    return DV*s if tau==math.inf else DV*tau*(1-math.exp(-s/tau))
def Dv(s,tau):
    if s<0: return 0.0
    return DV if tau==math.inf else DV*math.exp(-s/tau)
def run(rtt,mode,tau_m,direct,tau_true=TT):
    T0=0.2; Tc=T0+rtt; x=v=0.0; out=[]
    for k in range(int(2.5/DT)):
        t=k*DT
        if direct and abs(t-T0)<DT/2: v+=DV
        # uncompensated target: covered report view, impulse starts at Tc
        tx=D(t-Tc,tau_true); tv=Dv(t-Tc,tau_true) if t>=Tc else 0.0
        if mode=='drop' and T0<=t<Tc: tx+=D(t-T0,tau_m); tv+=Dv(t-T0,tau_m)
        if mode=='handoff' and t>=T0:
            tx+=D(t-T0,tau_m)-D(t-Tc,tau_m); tv+=Dv(t-T0,tau_m)-(Dv(t-Tc,tau_m) if t>=Tc else 0)
        a=W*W*(tx-x)+2*W*(tv-v); v+=a*DT; x+=v*DT; out.append((t,x))
    fin=out[-1][1]; peak=-1e9; retreat=0; over=max(p for _,p in out)-fin; lag=None
    for t,p in out:
        peak=max(peak,p); retreat=max(retreat,peak-p)
        if lag is None and p>=0.5*fin: lag=t-T0
    return retreat,over,lag*1000,fin
print("final true displacement",DV*TT)
for direct in (True,False):
  print("\nDIRECT APPLY" if direct else "\nTARGET ONLY")
  for rtt in (0.05,0.15,0.25):
    for mode,tm in (('none',None),('drop',math.inf),('drop',TT),('handoff',TT),('handoff',0.5),('handoff',0.06)):
      r,o,l,f=run(rtt,mode,tm,direct)
      print(f"rtt {int(rtt*1000):3d} {mode:8s} tau_model {('inf' if tm==math.inf else tm and int(tm*1000)) or '-':>4}  retreat {r:6.1f}  overshoot {o:6.1f}  lag50 {l:5.0f} ms")
