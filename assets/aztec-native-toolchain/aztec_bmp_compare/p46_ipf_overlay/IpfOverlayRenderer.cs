using System;
using System.IO;
using System.Globalization;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class P46IpfRenderer
{
    public sealed class Sources {
        public int W,H; public int[] Phase, Gray, Grain, Right, Bottom; public bool[] Invalid; public byte[] Rgb;
    }
    public sealed class PixelImage {
        public int W,H; public byte[] Data;
        public PixelImage(string path) { using(var b=new Bitmap(path)) { W=b.Width;H=b.Height; Data=Read(b); } }
        public PixelImage(int w,int h,byte[] d) { W=w;H=h;Data=d; }
        public void Save(string path) {
            if(File.Exists(path)) throw new IOException("Refusing overwrite: "+path);
            using(var b=new Bitmap(W,H,PixelFormat.Format24bppRgb)) {
                var d=b.LockBits(new Rectangle(0,0,W,H),ImageLockMode.WriteOnly,PixelFormat.Format24bppRgb);
                try { for(int y=0;y<H;y++) Marshal.Copy(Data,y*W*3,IntPtr.Add(d.Scan0,y*d.Stride),W*3); } finally { b.UnlockBits(d); }
                b.Save(path,ImageFormat.Bmp);
            }
        }
    }
    static byte[] Read(Bitmap b) {
        var a=new byte[b.Width*b.Height*3];
        var d=b.LockBits(new Rectangle(0,0,b.Width,b.Height),ImageLockMode.ReadOnly,PixelFormat.Format24bppRgb);
        try { for(int y=0;y<b.Height;y++) Marshal.Copy(IntPtr.Add(d.Scan0,y*d.Stride),a,y*b.Width*3,b.Width*3); } finally { b.UnlockBits(d); }
        return a;
    }
    static string[] Fields(string s) { var a=s.Split(',');for(int i=0;i<a.Length;i++)a[i]=a[i].Trim('"','\uFEFF');return a; }
    static int Int(string s) { return int.Parse(s,CultureInfo.InvariantCulture); }
    public static Sources Load(string pointBmp,string auditCsv,string bcCsv,int w,int h) {
        var p=new PixelImage(pointBmp); if(p.W!=w||p.H!=h)throw new Exception("Point bitmap grid mismatch");
        int n=w*h;var s=new Sources{W=w,H=h,Rgb=p.Data,Phase=new int[n],Gray=new int[n],Grain=new int[n],Right=new int[n],Bottom=new int[n],Invalid=new bool[n]};
        var seen=new bool[n];
        using(var r=new StreamReader(auditCsv)) {
            var a=Fields(r.ReadLine());var cols=new Dictionary<string,int>();for(int j=0;j<a.Length;j++)cols[a[j]]=j;
            string line;while((line=r.ReadLine())!=null) { a=Fields(line);int i=Int(a[cols["Index"]]);if(i<0||i>=n||seen[i])throw new Exception("Audit index mismatch");seen[i]=true;
                s.Phase[i]=Int(a[cols["PhaseId"]]);s.Grain[i]=Int(a[cols["GrainId"]]);s.Right[i]=Int(a[cols["BoundaryRight"]]);s.Bottom[i]=Int(a[cols["BoundaryBottom"]]);
                s.Invalid[i]=a[cols["InvalidGrain"]]=="1"||a[cols["InvalidGrain"]].Equals("true",StringComparison.OrdinalIgnoreCase);
            }
        }
        for(int i=0;i<n;i++)if(!seen[i])throw new Exception("Missing audit row");Array.Clear(seen,0,n);
        using(var r=new StreamReader(bcCsv)) {
            var a=Fields(r.ReadLine());var cols=new Dictionary<string,int>();for(int j=0;j<a.Length;j++)cols[a[j]]=j;
            string line;while((line=r.ReadLine())!=null) { a=Fields(line);int i=Int(a[cols["Index"]]);if(i<0||i>=n||seen[i])throw new Exception("BC index mismatch");seen[i]=true;
                if(Int(a[cols["PhaseId"]])!=s.Phase[i])throw new Exception("BC/Audit phase mismatch");
                int g=Int(a[cols["NativeR"]]);if(g<0||g>255||g!=Int(a[cols["NativeG"]])||g!=Int(a[cols["NativeB"]]))throw new Exception("Native BC is not grayscale");s.Gray[i]=g;
            }
        }
        for(int i=0;i<n;i++)if(!seen[i])throw new Exception("Missing BC row");return s;
    }
    public static int Axis(int d,int source,int destination,bool y) {
        return Math.Min(source-1,(int)((long)(y?Math.Max(d-1,0):d+1)*source/destination));
    }
    static bool Include(Sources s,int a,int b,string filter) {
        if(filter=="all_flags")return true;
        return s.Phase[a]>0&&s.Phase[a]==s.Phase[b]&&!s.Invalid[a]&&!s.Invalid[b];
    }
    public static PixelImage Render(Sources s,PixelImage layout,int rx,int ry,int rw,int rh,string layer,string mix,string filter,string position) {
        var dst=(byte[])layout.Data.Clone();bool bc=layer=="bc"||layer=="bc_gb",gb=layer=="gb"||layer=="bc_gb";
        var mx=new int[rw];var my=new int[rh];var firstX=new int[s.W];var firstY=new int[s.H];var lastX=new int[s.W];var lastY=new int[s.H];
        for(int i=0;i<s.W;i++)firstX[i]=-1;for(int i=0;i<s.H;i++)firstY[i]=-1;
        for(int x=0;x<rw;x++) { int i=Axis(x,s.W,rw,false);mx[x]=i;if(firstX[i]<0)firstX[i]=x;lastX[i]=x; }
        for(int y=0;y<rh;y++) { int i=Axis(y,s.H,rh,true);my[y]=i;if(firstY[i]<0)firstY[i]=y;lastY[i]=y; }
        for(int y=0;y<rh;y++)for(int x=0;x<rw;x++) {
            int i=my[y]*s.W+mx[x],o=((ry+y)*layout.W+rx+x)*3;
            for(int c=0;c<3;c++) { int v=s.Rgb[i*3+c];if(bc) { int g=s.Gray[i];v=s.Phase[i]==0?g:(mix=="floor_half"?(v+g)/2:(v+g+1)/2); }dst[o+c]=(byte)v; }
        }
        if(gb)for(int y=0;y<s.H;y++)for(int x=0;x<s.W;x++) {
            int i=y*s.W+x;
            if(x+1<s.W&&s.Right[i]!=0&&Include(s,i,i+1,filter)) {
                int dx=position=="next"?firstX[x+1]:lastX[x];
                if(dx>=0&&firstY[y]>=0)for(int dy=firstY[y];dy<=lastY[y];dy++)Black(dst,layout.W,rx+dx,ry+dy);
            }
            if(y+1<s.H&&s.Bottom[i]!=0&&Include(s,i,i+s.W,filter)) {
                int dy=position=="next"?firstY[y+1]:lastY[y];
                if(dy>=0&&firstX[x]>=0)for(int dx=firstX[x];dx<=lastX[x];dx++)Black(dst,layout.W,rx+dx,ry+dy);
            }
        }
        return new PixelImage(layout.W,layout.H,dst);
    }
    static void Black(byte[] dst,int w,int x,int y) {int o=(y*w+x)*3;dst[o]=dst[o+1]=dst[o+2]=0;}
    public sealed class Comparison {public long Pixels,Exact;public double Mae,Rmse;public int Max;}
    public static Comparison Compare(PixelImage actual,PixelImage reference,int rx,int ry,int rw,int rh,Sources s,bool pointCenters) {
        if(actual.W!=reference.W||actual.H!=reference.H)throw new Exception("Canvas mismatch");
        var m=new Comparison();double sum=0,sq=0;
        if(!pointCenters) {
            for(int y=ry;y<ry+rh;y++)for(int x=rx;x<rx+rw;x++)Accumulate(actual.Data,reference.Data,(y*actual.W+x)*3,m,ref sum,ref sq);
        } else {
            for(int y=1;y<s.H-1;y++)for(int x=1;x<s.W-1;x++) {
                int i=y*s.W+x;if(s.Phase[i]<=0||s.Invalid[i])continue;
                int dx=0,dy=0,xc=0,yc=0;
                for(int d=0;d<rw;d++)if(Axis(d,s.W,rw,false)==x){dx+=d;xc++;}
                for(int d=0;d<rh;d++)if(Axis(d,s.H,rh,true)==y){dy+=d;yc++;}
                if(xc==0||yc==0)continue;
                Accumulate(actual.Data,reference.Data,((ry+dy/yc)*actual.W+rx+dx/xc)*3,m,ref sum,ref sq);
            }
        }
        if(m.Pixels>0){m.Mae=sum/(m.Pixels*3.0);m.Rmse=Math.Sqrt(sq/(m.Pixels*3.0));}return m;
    }
    static void Accumulate(byte[] a,byte[] b,int o,Comparison m,ref double sum,ref double sq) {
        int max=0;for(int c=0;c<3;c++){int e=Math.Abs(a[o+c]-b[o+c]);max=Math.Max(max,e);sum+=e;sq+=e*e;}
        m.Pixels++;if(max==0)m.Exact++;m.Max=Math.Max(m.Max,max);
    }
}
