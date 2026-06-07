// oled-dash: ECG heart-monitor style system display for the M28K 0.91" OLED
// (SSD1306 128x32 via the ssd130x DRM fbdev /dev/fb0, 32bpp emulation).
//
// A synthetic PQRST cardiac waveform is "drawn" by a left->right sweeping beam
// with a blank erase gap chasing it (just like a hospital monitor). The heart
// RATE tracks CPU load: idle ~60 BPM, full load ~180 BPM, so the box literally
// "beats faster" when busy. The bottom line ROTATES through a different stat on
// each sweep -- CPU%, RAM%, clock (HH:MM), uptime (UP h:mm), then the IPv4 -- so
// every scan reveals fresh data (a page changes every 2 sweeps: the first sweep
// scans the new value in, the second holds it steady & readable).
//
// The single beam paints the WHOLE column it passes: ECG trace, the dashed
// separator, AND the current bottom stat -- so the text is revealed in lockstep
// with the scan line and erased by the same chasing gap (it "scans" with the
// beam). OLED burn-in care: every column is fully cleared & repainted
// each sweep (no permanently-lit pixel), the ECG baseline drifts, the separator
// dash phase and the text center slowly orbit, and the panel rests periodically.
//
// Build:  cc -O2 -o oled-dash oled-dash.c -lm

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/fb.h>

static int fbfd=-1; static unsigned char *fbp,*shadow; static int W,H,STRIDE; static long SZ;

// 5x7 font: ' ' . % : 0-9 and the uppercase letters used by the rotating stats and
// NIC names (A B C D E G H I L M N O P R S T U W). NIC names are shown upper-cased.
static const unsigned char F_SP[7]={0,0,0,0,0,0,0};
static const unsigned char F_DOT[7]={0,0,0,0,0,0x0C,0x0C};
static const unsigned char F_PCT[7]={0x18,0x19,0x02,0x04,0x08,0x13,0x03};
static const unsigned char F_COL[7]={0,0x04,0x04,0,0x04,0x04,0};       // ':'
static const unsigned char F_A[7]={0x0E,0x11,0x11,0x1F,0x11,0x11,0x11};
static const unsigned char F_B[7]={0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E};
static const unsigned char F_C[7]={0x0E,0x11,0x10,0x10,0x10,0x11,0x0E};
static const unsigned char F_D[7]={0x1C,0x12,0x11,0x11,0x11,0x12,0x1C};
static const unsigned char F_E[7]={0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F};
static const unsigned char F_G[7]={0x0E,0x11,0x10,0x17,0x11,0x11,0x0E};
static const unsigned char F_H[7]={0x11,0x11,0x11,0x1F,0x11,0x11,0x11};
static const unsigned char F_I[7]={0x0E,0x04,0x04,0x04,0x04,0x04,0x0E};
static const unsigned char F_L[7]={0x10,0x10,0x10,0x10,0x10,0x10,0x1F};
static const unsigned char F_M[7]={0x11,0x1B,0x15,0x15,0x11,0x11,0x11};
static const unsigned char F_N[7]={0x11,0x19,0x19,0x15,0x13,0x13,0x11};
static const unsigned char F_O[7]={0x0E,0x11,0x11,0x11,0x11,0x11,0x0E};
static const unsigned char F_P[7]={0x1E,0x11,0x11,0x1E,0x10,0x10,0x10};
static const unsigned char F_R[7]={0x1E,0x11,0x11,0x1E,0x14,0x12,0x11};
static const unsigned char F_S[7]={0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E};
static const unsigned char F_T[7]={0x1F,0x04,0x04,0x04,0x04,0x04,0x04};
static const unsigned char F_U[7]={0x11,0x11,0x11,0x11,0x11,0x11,0x0E};
static const unsigned char F_W[7]={0x11,0x11,0x11,0x15,0x15,0x1B,0x11};
static const unsigned char F_DIG[10][7]={
	{0x0E,0x11,0x13,0x15,0x19,0x11,0x0E},{0x04,0x0C,0x04,0x04,0x04,0x04,0x0E},
	{0x0E,0x11,0x01,0x02,0x04,0x08,0x1F},{0x1F,0x02,0x04,0x02,0x01,0x11,0x0E},
	{0x02,0x06,0x0A,0x12,0x1F,0x02,0x02},{0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E},
	{0x06,0x08,0x10,0x1E,0x11,0x11,0x0E},{0x1F,0x01,0x02,0x04,0x08,0x08,0x08},
	{0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E},{0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C}};
static const unsigned char *glyph(char c){
	if(c>='0'&&c<='9')return F_DIG[c-'0'];
	switch(c){
		case '.':return F_DOT; case '%':return F_PCT; case ':':return F_COL;
		case 'A':return F_A; case 'B':return F_B; case 'C':return F_C; case 'D':return F_D;
		case 'E':return F_E; case 'G':return F_G; case 'H':return F_H; case 'I':return F_I;
		case 'L':return F_L; case 'M':return F_M; case 'N':return F_N; case 'O':return F_O;
		case 'P':return F_P; case 'R':return F_R; case 'S':return F_S; case 'T':return F_T;
		case 'U':return F_U; case 'W':return F_W; }
	return F_SP; }

static long now_us(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec*1000000L+t.tv_nsec/1000; }
static void usleep_(long us){ if(us>0){ struct timespec t={us/1000000,(us%1000000)*1000}; nanosleep(&t,NULL);} }
static void setpx(int x,int y,int on){ if(x<0||y<0||x>=W||y>=H)return; *(unsigned int*)(shadow+(long)y*STRIDE+(long)x*4)= on?0xFFFFFFFFu:0u; }
static void colclear(int x,int y0,int y1){ for(int y=y0;y<=y1;y++) setpx(x,y,0); }
static void vseg(int x,int ya,int yb){ if(ya>yb){int t=ya;ya=yb;yb=t;} for(int y=ya;y<=yb;y++) setpx(x,y,1); }
static int  tw(const char*s){ int n=strlen(s); return n>0?n*6-1:0; }

static void present(void){ memcpy(fbp,shadow,SZ); msync(fbp,SZ,MS_SYNC); }
static void blank(int on){ if(fbfd>=0) ioctl(fbfd,FBIOBLANK,on?FB_BLANK_POWERDOWN:FB_BLANK_UNBLANK); }

static int cpu_pct(void){ static long pt=0,pi=0; long t=0,idle=0,u,n,s,i,io,ir,si,st; FILE*f=fopen("/proc/stat","r"); if(!f)return -1;
	if(fscanf(f,"cpu %ld %ld %ld %ld %ld %ld %ld %ld",&u,&n,&s,&i,&io,&ir,&si,&st)==8){t=u+n+s+i+io+ir+si+st;idle=i+io;} fclose(f);
	long dt=t-pt,di=idle-pi; pt=t; pi=idle; if(dt<=0)return -1; int p=(int)((dt-di)*100/dt); return p<0?0:(p>100?100:p); }
// Every non-loopback IPv4 address with its NIC name (eth0, wlan0, …) — each becomes
// its own rotating page, so a multi-homed box shows all of its interfaces in turn.
// The name is upper-cased to match the font (and the all-caps CPU/RAM/UP labels).
#define MAXIP 6
static char g_ifs[MAXIP][12]; static char g_ips[MAXIP][24]; static int g_nips=0;
static void read_ips(void){ g_nips=0;
	FILE*f=popen("ip -4 -o addr show 2>/dev/null|awk '$2!=\"lo\"{split($4,a,\"/\");print $2, a[1]}'","r");
	if(!f)return;
	char ifn[32], ip[40];
	while(g_nips<MAXIP && fscanf(f,"%31s %39s",ifn,ip)==2){
		int j; for(j=0;j<(int)sizeof g_ifs[0]-1 && ifn[j];j++){ char c=ifn[j]; g_ifs[g_nips][j]=(c>='a'&&c<='z')?c-32:c; }
		g_ifs[g_nips][j]=0;
		strncpy(g_ips[g_nips],ip,sizeof g_ips[0]-1); g_ips[g_nips][sizeof g_ips[0]-1]=0;
		g_nips++; }
	pclose(f); }

static long mem_used_kb(void){ long total=0,avail=0,v; char line[128]; FILE*f=fopen("/proc/meminfo","r"); if(!f)return -1;
	while(fgets(line,sizeof line,f)){ if(sscanf(line,"MemTotal: %ld",&v)==1)total=v; else if(sscanf(line,"MemAvailable: %ld",&v)==1)avail=v; }
	fclose(f); if(total<=0)return -1; long used=total-avail; return used<0?0:used; }
static long uptime_s(void){ double u=0; FILE*f=fopen("/proc/uptime","r"); if(!f)return 0; if(fscanf(f,"%lf",&u)!=1)u=0; fclose(f); return (long)u; }

// Bottom-line stat pages, rotated one per (pair of) sweeps. The value is frozen
// for the page's whole window so the scanned-in text stays internally coherent.
// Pages 0..3 are fixed (CPU/RAM/clock/uptime); 4.. are one per NIC IPv4 address.
#define NFIXED 4
static int npages(void){ return NFIXED + (g_nips>0?g_nips:1); }
static void build_page(int page,char*o,int n,int cpu){
	switch(page){
		case 0: snprintf(o,n,"CPU %d%%",cpu); break;
		// actual RAM in use, auto-scaled unit: <1000 MiB shown as M, else G (1 dp).
		case 1: { long u=mem_used_kb();
			if(u<0) snprintf(o,n,"RAM --");
			else if(u < 1000L*1024) snprintf(o,n,"RAM %ldM",(u+512)/1024);
			else snprintf(o,n,"RAM %.1fG",u/1048576.0); } break;
		case 2: { time_t tt=time(NULL); struct tm lt; localtime_r(&tt,&lt); snprintf(o,n,"%02d:%02d",lt.tm_hour,lt.tm_min); } break;
		case 3: { long up=uptime_s(); snprintf(o,n,"UP %ld:%02ld",up/3600,(up%3600)/60); } break;
		default: { int k=page-NFIXED; if(k>=0&&k<g_nips) snprintf(o,n,"%s %s",g_ifs[k],g_ips[k]); else snprintf(o,n,"no-ip"); } break;
	}
}

// synthetic ECG (one cardiac cycle over phase t in [0,1)): P Q R S T
static float ecg(float t){
	float v=0;
	v += 0.10f*expf(-((t-0.20f)*(t-0.20f))/(2*0.022f*0.022f));   // P
	v += -0.14f*expf(-((t-0.37f)*(t-0.37f))/(2*0.012f*0.012f));  // Q
	v += 1.00f*expf(-((t-0.40f)*(t-0.40f))/(2*0.011f*0.011f));   // R
	v += -0.30f*expf(-((t-0.44f)*(t-0.44f))/(2*0.012f*0.012f));  // S
	v += 0.30f*expf(-((t-0.62f)*(t-0.62f))/(2*0.035f*0.035f));   // T
	return v;
}

int main(void){
	fbfd=open("/dev/fb0",O_RDWR); if(fbfd<0)return 0;
	struct fb_var_screeninfo v; struct fb_fix_screeninfo fx;
	if(ioctl(fbfd,FBIOGET_VSCREENINFO,&v)||ioctl(fbfd,FBIOGET_FSCREENINFO,&fx))return 0;
	W=v.xres;H=v.yres;STRIDE=fx.line_length;SZ=(long)STRIDE*H; if(v.bits_per_pixel!=32)return 0;
	fbp=mmap(NULL,SZ,PROT_READ|PROT_WRITE,MAP_SHARED,fbfd,0); if(fbp==MAP_FAILED)return 0;
	shadow=malloc(SZ); if(!shadow)return 0;
	(void)system("for v in /sys/class/vtconsole/vtcon*/bind; do grep -q 'frame buffer' \"$(dirname \"$v\")/name\" 2>/dev/null && echo 0 > \"$v\"; done 2>/dev/null");

	const int TOP=0, BOT=22, SEP=23, TY=25;     // trace band / separator / text row
	const float FPS=60.0f, PXPS=46.0f;          // beam paper speed (px/sec)
	const int GAP=4;                            // blank erase gap ahead of beam
	const float AMP=15.0f;                      // R-wave height in px
	const int TROWS=7;                           // glyph rows in the text band

	memset(shadow,0,SZ);
	read_ips();
	cpu_pct(); blank(0);

	float disp=0,target=0;                       // smoothed CPU for the rate
	float headx=0, phase=0, blf=16;              // beam x, ecg phase, baseline (drifts)
	int prevcol=-1, prevy=16;
	unsigned char tcol[1024];                    // per-column bitmap of the bottom text
	const long FRAME=(long)(1000000/FPS);
	long frame=0, next=now_us();
	int wraps=0, page=-1; char pagebuf[80];      // rotating bottom-line stat (per 2 sweeps)

	for(;;){
		if(frame%12==0){ int c=cpu_pct(); if(c>=0)target=(float)c; }
		if(frame%600==0) read_ips();   // re-enumerate NICs (a wlan0 may come/go)
		// pick the bottom stat: one page per 2 sweeps; freeze its value on entry.
		int np=(wraps/2)%npages();
		if(np!=page){ page=np; build_page(page,pagebuf,sizeof pagebuf,(int)(target+0.5f)); }
		disp += (target-disp)*0.15f;
		float bpm = 60.0f + disp*1.2f;           // CPU -> heart rate

		// periodic panel rest (burn-in): ~10s every 300s, not at boot
		long sec=frame/(long)FPS;
		if(frame>180 && sec%300>=290){ blank(1); usleep_(500000); frame+=30; next=now_us(); continue; }
		blank(0);

		// slow baseline drift (burn-in); within one sweep it's effectively constant
		blf = 16.0f + 2.0f*sinf(frame*0.0016f);
		int BL=(int)lroundf(blf);

		// Rasterize the current stat page into a per-column bitmap (bit r = row TY+r).
		// Its horizontal center slowly orbits a few px so the glyph pixels roam
		// across the panel over time (burn-in). The beam below paints these
		// columns in step with the sweep, so the text "scans" with the scan line.
		memset(tcol,0,sizeof tcol);
		{ int orbit=(int)lroundf(3.0f*sinf(frame*0.0010f));
		  int x0=(W-tw(pagebuf))/2+orbit, gx=x0;
		  for(const char*s=pagebuf; *s; s++,gx+=6){ const unsigned char*g=glyph(*s);
			for(int r=0;r<TROWS;r++) for(int c=0;c<5;c++)
				if(g[r]&(1<<(4-c))){ int xx=gx+c; if(xx>=0&&xx<W) tcol[xx]|=(unsigned char)(1<<r); } } }
		int sepph=(int)(frame/20);                // dashed-separator phase drifts

		// advance the sweeping beam; it repaints the FULL column it crosses:
		// ECG trace + dashed separator + bottom-text bits (all swept together).
		float step = PXPS/FPS;
		float newhead = headx + step;
		float dphase = (bpm/60.0f)/PXPS;         // cycles advanced per pixel
		int from=(int)headx, to=(int)newhead;
		for(int ix=from+1; ix<=to; ix++){
			phase += dphase; if(phase>=1.0f) phase-=1.0f;
			int col=ix%W;
			colclear(col,TOP,H-1);                       // erase the whole column
			if(((col+sepph)&3)==0) setpx(col,SEP,1);     // dashed separator
			unsigned char tb=tcol[col];                  // bottom text for this column
			for(int r=0;r<TROWS;r++) if(tb&(1<<r)) setpx(col,TY+r,1);
			int y=BL-(int)lroundf(ecg(phase)*AMP); if(y<TOP)y=TOP; if(y>BOT)y=BOT;
			if(col==(prevcol+1)%W && col!=0) vseg(col,prevy,y); else setpx(col,y,1);
			prevcol=col; prevy=y;
		}
		headx=newhead; if(headx>=W){ headx-=W; wraps++; }   // completed a full sweep
		for(int g=1;g<=GAP;g++) colclear(((int)headx+g)%W,TOP,H-1);   // blank gap ahead (full column)

		present();
		next+=FRAME; long d=next-now_us(); if(d>0)usleep_(d); else next=now_us();
		frame++;
	}
	return 0;
}
