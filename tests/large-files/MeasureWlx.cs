using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class WlxTest
{
    [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet=CharSet.Unicode)]
    private delegate IntPtr LoadW(IntPtr parent, string path, int flags);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate void CloseW(IntPtr view);
    [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet=CharSet.Unicode)]
    private delegate int FindW(IntPtr view, string text, int flags);
    private delegate bool Enumerate(IntPtr hwnd, IntPtr data);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr LoadLibrary(string name);
    [DllImport("kernel32.dll", ExactSpelling=true)] private static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool EnumThreadWindows(uint thread, Enumerate visit, IntPtr data);
    [DllImport("user32.dll")] private static extern IntPtr GetDlgItem(IntPtr wnd, int id);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr wnd, StringBuilder name, int max);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr wnd, StringBuilder text, int max);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern bool SetWindowText(IntPtr wnd, string text);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr SendMessage(IntPtr wnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] private static extern bool MoveWindow(IntPtr wnd, int x, int y, int width, int height, bool repaint);
    [DllImport("user32.dll")] private static extern bool RedrawWindow(IntPtr wnd, IntPtr rectangle, IntPtr region, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    private struct Hdr { public IntPtr Window, Id; public int Code; }
    [StructLayout(LayoutKind.Sequential)]
    private struct ListItem
    {
        public uint Mask; public int Row, Sub; public uint State, StateMask;
        public IntPtr Text; public int Cap, Image; public IntPtr Param;
        public int Indent, Group; public uint Columns; public IntPtr Col, ColFmt; public int GroupIndex;
    }
    private sealed class Host : Form { protected override bool ShowWithoutActivation { get { return true; } } }
    private static IntPtr view, grid, tree, status, tabs, text;
    private static long peak;
    private static readonly Process Proc = Process.GetCurrentProcess();

    private static T Export<T>(IntPtr dll, string name) where T:class
    {
        var p=GetProcAddress(dll,name);
        Need(p!=IntPtr.Zero,"missing export " + name);
        return Marshal.GetDelegateForFunctionPointer(p,typeof(T)) as T;
    }
    private static void Need(bool ok,string message) { if(!ok) throw new InvalidOperationException(message); }
    private static IntPtr S(IntPtr h,uint m,int w,int l) { return SendMessage(h,m,(IntPtr)w,(IntPtr)l); }
    private static string Text(IntPtr h, int cap=2048) { var b=new StringBuilder(cap); GetWindowText(h,b,b.Capacity); return b.ToString(); }
    private static string Class(IntPtr h) { var b=new StringBuilder(128); GetClassName(h,b,b.Capacity); return b.ToString(); }
    private static string Cell(int row, int col)
    {
        var h=Marshal.AllocHGlobal(1024);
        var p=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(ListItem)));
        try {
            Marshal.WriteInt16(h,0);
            var item=new ListItem { Row=row, Sub=col, Text=h, Cap=512 };
            Marshal.StructureToPtr(item,p,false);
            SendMessage(grid,0x1073,(IntPtr)row,p);
            return Marshal.PtrToStringUni(h);
        }
        finally { Marshal.FreeHGlobal(p); Marshal.FreeHGlobal(h); }
    }
    private static int Rows() { return S(grid,0x1004,0,0).ToInt32(); }
    private static IntPtr Child(int id) { return GetDlgItem(view,id); }
    private static void Pump()
    {
        Application.DoEvents();
        Proc.Refresh();
        peak=Math.Max(peak,Proc.PrivateMemorySize64);
        Thread.Sleep(5);
    }
    private static long Await(Func<bool> ready, string stage, Stopwatch clock=null)
    {
        clock=clock??Stopwatch.StartNew();
        while(!ready()) {
            Pump();
            var state=Text(status);
            if (state.Contains("Partial:")) throw new InvalidOperationException(state);
            if (clock.ElapsedMilliseconds>240000) throw new TimeoutException(stage+" "+state);
        }
        RedrawWindow(view,IntPtr.Zero,IntPtr.Zero,0x0181);
        Pump();
        var ms=clock.ElapsedMilliseconds;
        Console.WriteLine(stage+"_ms="+ms);
        return ms;
    }
    private static void Cmd(int id, int notification=0) { SendMessage(view,0x0111,(IntPtr)(id|(notification<<16)),Child(id)); }
    private static void SelectCombo(int id, string match)
    {
        var h=Child(id);
        int count=S(h,0x0146,0,0).ToInt32();
        for(int i=0;i<count;i++) {
            var n=S(h,0x0149,i,0).ToInt32();
            var buffer=Marshal.AllocHGlobal((n+1)*2);
            try {
                SendMessage(h,0x0148,(IntPtr)i,buffer);
                if (Marshal.PtrToStringUni(buffer)!=match) continue;
                S(h,0x014e,i,0);
                Cmd(id,1);
                return;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        throw new InvalidOperationException("Missing option "+match);
    }
    private static void Tab(int n)
    {
        S(tabs,0x130c,n,0);
        var p=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Hdr)));
        try {
            Marshal.StructureToPtr(new Hdr { Window=tabs, Id=(IntPtr)104, Code=-551 },p,false);
            SendMessage(view,0x004e,(IntPtr)104,p);
        }
        finally { Marshal.FreeHGlobal(p); }
    }

    private static void Filter(string field, string pattern)
    {
        SelectCombo(107, field);
        SetWindowText(Child(108), pattern);
    }
    private static void AssertLiveFilter()
    {
        Await(()=>Rows()==2048 && Text(status).Contains("Indexed"),"live_index");
        Need(Child(109)==IntPtr.Zero && Child(110)!=IntPtr.Zero,"filter buttons");

        SelectCombo(107,"session");
        var editor=Child(108);
        foreach(char c in "00") S(editor,0x0102,c,1);
        Need(Text(editor)=="00","filter editor typed value");
        Await(()=>Rows()==32 && Text(status).Contains("Filtered"),"live_grid");

        Tab(1);
        Filter("late","eed");
        Await(()=>Rows()==1 && Text(text).Contains("needle"),"live_text");
        SelectCombo(107,"session");
        Need(Text(editor)=="00","restore column filter");
        SetWindowText(editor,"");
        Await(()=>Rows()==64 && Text(text).Contains("needle"),"remove_single_filter");

        SetWindowText(editor,"willnotmatch");
        Cmd(110);
        Await(()=>Rows()==2048 && !Text(status).Contains("Filtered"),"clear_all");
        var settle=Stopwatch.StartNew();
        while(settle.ElapsedMilliseconds<400) Pump();
        Need(Rows()==2048 && Text(editor)=="" && !Text(status).Contains("Filtered"),
            "clear must cancel a pending filter");
    }

    private static void AssertRefresh(string path)
    {
        Await(()=>Rows()==2 && Text(status).Contains("Indexed") && Cell(1,0)=="2","before_append");
        File.AppendAllText(path, "\n{\"id\":3,\"newfield\":true}\n");
        Cmd(113);
        Await(()=>Rows()==3 && Text(status).Contains("Indexed") && Cell(2,0)=="3","after_append");
        Need(Cell(2,1)=="true","late field value after append");
        string replacement=path+".next";
        File.WriteAllText(replacement,"{\"id\":7}\n");
        File.Replace(replacement,path,null);
        Cmd(113);
        Await(()=>Rows()==1 && Text(status).Contains("Indexed") && Cell(0,0)=="7","after_replace");
    }

    private static void AssertLongRecord()
    {
        Await(()=>Rows()==3 && Text(status).Contains("Indexed") && Cell(0,0)=="0","long_index");
        SelectCombo(106,"kind");
        Await(()=>Text(status).Contains("Groups: 3") && !Text(status).Contains("building"),"typed_groups");
        Filter("blob","=willnotmatch");
        Filter("blob","tailToken");
        Await(()=>Rows()==1 && Text(status).Contains("Filtered") && Cell(0,0)=="0","long_filter");
        var item=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(ListItem)));
        try {
            Marshal.StructureToPtr(new ListItem { State=2, StateMask=2 },item,false);
            SendMessage(grid,0x102b,IntPtr.Zero,item);
        } finally { Marshal.FreeHGlobal(item); }
        Tab(1);
        Await(()=>Text(text,400).Contains("\"blob\""),"long_text");
        Cmd(112);
        Await(()=>!Text(text,400).Contains("\"blob\"") && Text(text,400).Contains("a"),"long_text_next");
        Cmd(111);
        Await(()=>Text(text,400).Contains("\"blob\""),"long_text_prev");
        SelectCombo(106,"Group by: file order");
        SelectCombo(106,"blob");
        Await(()=>Text(status).Contains("Groups: 2") && !Text(status).Contains("building"),"long_group_key");
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try {
            Application.EnableVisualStyles();
            using(var host=new Host { Width=1360,Height=780,ShowInTaskbar=false,
                StartPosition=FormStartPosition.Manual,Location=new Point(-29000,-29000) }) {
                host.Show();
                IntPtr dll=LoadLibrary(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"jsontab.wlx64"));
                Need(dll!=IntPtr.Zero,"load DLL (Win32 error "+Marshal.GetLastWin32Error()+")");
                var open=Export<LoadW>(dll,"ListLoadW");
                var close=Export<CloseW>(dll,"ListCloseWindow");
                var find=Export<FindW>(dll,"ListSearchTextW");
                string path=Path.GetFullPath(args[0]);
                string mode=args.Length>1?args[1]:"bench";
                bool largeFixture=new FileInfo(path).Length>=1073741824;
                int dialogs=0;
                var warning=new System.Windows.Forms.Timer { Interval=10 };
                var watch=Stopwatch.StartNew();
                warning.Tick+=(sender,eventArgs)=>EnumThreadWindows(GetCurrentThreadId(),(w,p)=>{
                    if(Class(w)!="#32770")return true;
                    var b=GetDlgItem(w,mode=="cancel"?2:1);
                    if(b==IntPtr.Zero)return true;
                    dialogs++;
                    Console.WriteLine("dialog="+Text(w));
                    watch.Restart();
                    S(b,0x00f5,0,0);
                    return false;
                },IntPtr.Zero);
                warning.Start();
                view=open(host.Handle,path,128);
                warning.Dispose();
                if(mode=="cancel" || mode=="reject") {
                    Need(view==IntPtr.Zero,"file should not open");
                    Need(dialogs==(mode=="cancel"?1:0),"wrong dialog count");
                    Console.WriteLine(mode+"=PASS");
                    return 0;
                }
                Need(view!=IntPtr.Zero,"ListLoadW failed");
                try {
                    if(mode=="full") {
                        Need(Class(view)!="JsonTabStreamingViewer","expected full load");
                        Console.WriteLine("full=PASS");
                        return 0;
                    }
                    Need(Class(view)=="JsonTabStreamingViewer","expected streaming window");
                    Need(dialogs==(largeFixture?1:0),"wrong dialog count");
                    MoveWindow(view,0,0,host.ClientSize.Width,host.ClientSize.Height,true);
                    grid=Child(101);tree=Child(102);text=Child(103);tabs=Child(104);status=Child(105);
                    if(mode=="filter-ui") { AssertLiveFilter(); Console.WriteLine("filter-ui=PASS"); return 0; }
                    if(mode=="refresh") { AssertRefresh(path); Console.WriteLine("refresh=PASS"); return 0; }
                    if(mode=="long") { AssertLongRecord(); Console.WriteLine("long=PASS"); return 0; }
                    if(mode=="encoding") {
                        Await(()=>Rows()==2 && Text(status).Contains("Indexed"),"encoded_index");
                        Need(Cell(0,0)=="0" && Cell(1,1)=="éТ✓","encoded value "+Cell(1,1));
                        Console.WriteLine("encoding=PASS");
                        return 0;
                    }
                    if(mode=="ansi") {
                        Await(()=>Rows()==2 && Text(status).Contains("Indexed"),"ansi_index");
                        Need(Cell(1,1)==Encoding.Default.GetString(new byte[]{233}),"ANSI value "+Cell(1,1));
                        Console.WriteLine("ansi=PASS");
                        return 0;
                    }
                    if(mode=="broken") {
                        var timer=Stopwatch.StartNew();
                        while(!Text(status).Contains("Partial:")) { Pump(); Need(timer.ElapsedMilliseconds<5000,"missing parse error"); }
                        Need(Text(status).Contains("byte") && Rows()==1,"wrong partial result "+Text(status));
                        Console.WriteLine("broken=PASS");
                        return 0;
                    }
                    if(mode=="quick") {
                        Await(()=>Rows()>0 && Text(status).Contains("Indexed"),"quick_index",watch);
                        Console.WriteLine("quick=PASS");
                        return 0;
                    }
                    if(mode=="close-fast") {
                        Await(()=>Rows()>0 && Cell(0,0)=="0","first_painted",watch);
                        Need(!Text(status).Contains("Indexed"),"closed after indexing completed");
                        Console.WriteLine("close_while_indexing=PASS");
                        return 0;
                    }
                    int expected=largeFixture?262144:2048;
                    Await(()=>Rows()>0 && Cell(0,0)=="0","first_painted",watch);
                    Console.WriteLine("first_rows="+Rows());
                    Await(()=>Rows()==expected && Text(status).Contains("Indexed"),"indexed",watch);
                    foreach(int i in new[]{expected/2,expected-1,0,expected/2})
                    {
                        var jump=Stopwatch.StartNew();
                        S(grid,0x1013,i,0);
                        Await(()=>Cell(i,0)==i.ToString(),"jump_"+i,jump);
                    }
                    SelectCombo(106,"session");
                    Await(()=>Text(status).Contains("Groups: 64") && !Text(status).Contains("building"),"grouped");
                    var root=SendMessage(tree,0x110a,(IntPtr)0,IntPtr.Zero);
                    var g=SendMessage(tree,0x110a,(IntPtr)4,root);
                    Need(g!=IntPtr.Zero,"tree group node");
                    SendMessage(tree,0x110b,(IntPtr)9,g);
                    Await(()=>Rows()==expected/64 && Cell(0,0)=="0","selected_group");
                    SelectCombo(107,"late");
                    SetWindowText(Child(108),"=needle");
                    Await(()=>Rows()==1 && Text(status).Contains("Filtered") && Cell(0,0)==(expected-64).ToString(),"group_filter");
                    Tab(1);
                    Await(()=>Text(text).Contains("\"late\""),"text");
                    find(view,"needle",1);
                    Await(()=>Text(status).Contains("Search in current view: row 1"),"search");
                    Tab(0);
                    SelectCombo(106,"Group by: file order");
                    Await(()=>Rows()==64 && Text(status).Contains("Filtered"),"global_filter");
                    Console.WriteLine("peak_private="+peak);
                    Console.WriteLine("PASS");
                }
                finally { close(view); }
            }
            return 0;
        }
        catch(Exception e) { Console.Error.WriteLine(e); return 1; }
    }
}
