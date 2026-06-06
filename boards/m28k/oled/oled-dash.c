// oled-dash: ECG heart-monitor style system display for the M28K 0.91" OLED
// (SSD1306 128x32 via the ssd130x DRM fbdev /dev/fb0, 32bpp emulation).
//
// A synthetic PQRST cardiac waveform is "drawn" by a left->right sweeping beam
// with a blank erase gap chasing it (just like a hospital monitor). The heart
// RATE tracks CPU load: idle ~60 BPM, full load ~180 BPM, so the box literally
// "beats faster" when busy. Bottom line shows  "<cpu>% <ipv4>".
//
// The single beam paints the WHOLE column it passes: ECG trace, the dashed
// separator, AND the bottom "<cpu>% <ipv4>" text -- so the text is revealed in
// lockstep with the scan line and erased by the same chasing gap (it "scans"
// with the beam). OLED burn-in care: every column is fully cleared & repainted
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

// 5x7 font: ' ' . % 0-9 I P
static const unsigned char F_SP[7]={0,0,0,0,0,0,0};
static const unsigned char F_DOT[7]={0,0,0,0,0,0x0C,0x0C};
static const unsigned char F_PCT[7]={0x18,0x19,0x02,0x04,0x08,0x13,0x03};
static const unsigned char F_I[7]={0x0E,0x04,0x04,0x04,0x04,0x04,0x0E};
static const unsigned char F_P[7]={0x1E,0x11,0x11,0x1E,0x10,0x10,0x10};
static const unsigned char F_D[10][7]={
	{0x0E,0x11,0x13,0x15,0x19,0x11,0x0E},{0x04,0x0C,0x04,0x04,0x04,0x04,0x0E},
	{0x0E,0x11,0x01,0x02,0x04,0x08,0x1F},{0x1F,0x02,0x04,0x02,0x01,0x11,0x0E},
	{0x02,0x06,0x0A,0x12,0x1F,0x02,0x02},{0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E},
	{0x06,0x08,0x10,0x1E,0x11,0x11,0x0E},{0x1F,0x01,0x02,0x04,0x08,0x08,0x08},
	{0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E},{0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C}};
static const unsigned char *glyph(char c){
	if(c>='0'&&c<='9')return F_D[c-'0']; if(c=='.')return F_DOT; if(c=='%')return F_PCT;
	if(c=='I')return F_I; if(c=='P')return F_P; return F_SP; }

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
static void read_ip(char*o,int n){ o[0]=0; FILE*f=popen("ip -4 -o addr show 2>/dev/null|awk '$2!=\"lo\"{split($4,a,\"/\");print a[1];exit}'","r");
	if(!f)return; if(fgets(o,n,f)){char*p=strchr(o,'\n');if(p)*p=0;} pclose(f); }

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
	char ip[64]; read_ip(ip,sizeof ip);
	cpu_pct(); blank(0);

	float disp=0,target=0;                       // smoothed CPU for the rate
	float headx=0, phase=0, blf=16;              // beam x, ecg phase, baseline (drifts)
	int prevcol=-1, prevy=16;
	unsigned char tcol[1024];                    // per-column bitmap of the bottom text
	const long FRAME=(long)(1000000/FPS);
	long frame=0, next=now_us();

	for(;;){
		if(frame%12==0){ int c=cpu_pct(); if(c>=0)target=(float)c; }
		if(frame%600==0) read_ip(ip,sizeof ip);
		disp += (target-disp)*0.15f;
		float bpm = 60.0f + disp*1.2f;           // CPU -> heart rate

		// periodic panel rest (burn-in): ~10s every 300s, not at boot
		long sec=frame/(long)FPS;
		if(frame>180 && sec%300>=290){ blank(1); usleep_(500000); frame+=30; next=now_us(); continue; }
		blank(0);

		// slow baseline drift (burn-in); within one sweep it's effectively constant
		blf = 16.0f + 2.0f*sinf(frame*0.0016f);
		int BL=(int)lroundf(blf);

		// Rasterize the bottom text into a per-column bitmap (bit r = row TY+r).
		// Its horizontal center slowly orbits a few px so the glyph pixels roam
		// across the panel over time (burn-in). The beam below paints these
		// columns in step with the sweep, so the text "scans" with the scan line.
		char buf[80]; snprintf(buf,sizeof buf,"%d%% %s",(int)(target+0.5f), ip[0]?ip:"no-ip");
		memset(tcol,0,sizeof tcol);
		{ int orbit=(int)lroundf(3.0f*sinf(frame*0.0010f));
		  int x0=(W-tw(buf))/2+orbit, gx=x0;
		  for(const char*s=buf; *s; s++,gx+=6){ const unsigned char*g=glyph(*s);
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
		headx=newhead; if(headx>=W) headx-=W;
		for(int g=1;g<=GAP;g++) colclear(((int)headx+g)%W,TOP,H-1);   // blank gap ahead (full column)

		present();
		next+=FRAME; long d=next-now_us(); if(d>0)usleep_(d); else next=now_us();
		frame++;
	}
	return 0;
}
