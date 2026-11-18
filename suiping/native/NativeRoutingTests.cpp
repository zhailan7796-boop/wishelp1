#include "NativeHooks.h"
#include <cstdio>
#include <string>
#include <vector>
#include <stdexcept>

namespace {
unsigned Checks{};
struct Received { unsigned own{},compat{},serial{}; HMONITOR monitor{}; HWND window{}; } Messages;
void Check(bool value,const char* label) { if (!value) throw std::runtime_error(label); ++Checks; }
LRESULT CALLBACK Receive(HWND hwnd,UINT message,WPARAM wparam,LPARAM lparam) {
    if (message==0x8054) {
        ++Messages.own; Messages.monitor=reinterpret_cast<HMONITOR>(wparam);
        Messages.window=reinterpret_cast<HWND>(lparam); return 0;
    }
    if (message==0x8055) {
        ++Messages.compat; Messages.serial=static_cast<unsigned>(wparam);
        Messages.monitor=reinterpret_cast<HMONITOR>(lparam); return 0;
    }
    return DefWindowProcW(hwnd,message,wparam,lparam);
}
template<class Predicate> void Wait(Predicate predicate) {
    const ULONGLONG end=GetTickCount64()+2000;
    while (!predicate()) {
        MSG message{};
        while (PeekMessageW(&message,nullptr,0,0,PM_REMOVE)) { TranslateMessage(&message); DispatchMessageW(&message); }
        if (GetTickCount64()>end) throw std::runtime_error("owned routing message timeout");
        Sleep(1);
    }
}
void Drain() {
    MSG message{};
    while (PeekMessageW(&message,nullptr,0,0,PM_REMOVE)) { TranslateMessage(&message); DispatchMessageW(&message); }
}
BOOL CALLBACK Collect(HMONITOR monitor,HDC,LPRECT,LPARAM data) {
    reinterpret_cast<std::vector<HMONITOR>*>(data)->push_back(monitor); return TRUE;
}
using StartFn=BOOL(*)(HWND,unsigned);
using StopFn=BOOL(*)(unsigned);
using ReleaseFn=BOOL(*)(const NativeEntry*,HMONITOR,BOOL);
using IntentFn=BOOL(*)(unsigned,NativeIntent*,unsigned);
using CancelFn=void(*)(unsigned);
using CancelCompatibilityFn=BOOL(*)(unsigned);
using EnableFn=void(*)(BOOL);
using StatusFn=BOOL(*)(NativeStatus*,unsigned);
void CheckAppInput(HMODULE module,HMONITOR monitor) {
    auto mouse=reinterpret_cast<BOOL(*)(unsigned,int,int)>(GetProcAddress(module,"TF_TestMouseInput"));
    auto intent=reinterpret_cast<IntentFn>(GetProcAddress(module,"TF_CompatibilityIntent"));
    auto cancel=reinterpret_cast<CancelFn>(GetProcAddress(module,"TF_Cancel"));
    MONITORINFO info{sizeof(info)};
    Check(mouse && intent && cancel && GetMonitorInfoW(monitor,&info),"app click fixture APIs and monitor");
    const auto original=SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    struct DpiGuard { DPI_AWARENESS_CONTEXT context; ~DpiGuard() { SetThreadDpiAwarenessContext(context); } } dpi{original};
    const int left=info.rcWork.left+40, top=info.rcWork.top+60;
    const auto fixture=[&](int offset) {
        return CreateWindowExW(WS_EX_TOPMOST,L"TaskbarFollow.RoutingFixture",L"",WS_OVERLAPPEDWINDOW,
            left+offset,top,300,230,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
    };
    struct WindowGuard { HWND hwnd; ~WindowGuard() { if (hwnd) DestroyWindow(hwnd); } };
    WindowGuard source{fixture(0)}, visible{fixture(310)}, hidden{fixture(620)};
    Check(source.hwnd && visible.hwnd && hidden.hwnd,"create app input source and visible/hidden siblings");
    ShowWindow(source.hwnd,SW_SHOWNOACTIVATE); ShowWindow(visible.hwnd,SW_SHOWNOACTIVATE);
    const int x=left+90,y=top+100;
    Check(GetAncestor(WindowFromPoint({x,y}),GA_ROOT)==source.hwnd,"application is the physical hit target");
    const auto press=[&] { return mouse(WM_LBUTTONDOWN,x,y)!=FALSE; };
    const auto release=[&] { return mouse(WM_LBUTTONUP,x,y)!=FALSE; };
    const unsigned before=Messages.compat;
    Check(press(),"click an application window");
    ShowWindow(hidden.hwnd,SW_SHOWNOACTIVATE);
    Check(release(),"release an app click after another window becomes visible");
    Wait([&] {return Messages.compat==before+1;});
    NativeIntent opened{};
    Check(intent(Messages.serial,&opened,sizeof(opened)) && opened.entry.flags==TF_APP_LAUNCH
        && opened.monitor==reinterpret_cast<UINT_PTR>(monitor) && opened.source==reinterpret_cast<UINT_PTR>(source.hwnd)
        && opened.expires-opened.released==2000,"app intent freezes source, physical monitor, and expiry");
    Check(opened.entry.count>=2 && opened.entry.windows[0].hwnd==opened.source
        && opened.entry.windows[0].pid==GetCurrentProcessId(),"app intent pins its click source PID");
    bool foundVisible=false,foundHidden=false;
    for (unsigned i=0;i<opened.entry.count;++i) {
        foundVisible|=opened.entry.windows[i].hwnd==reinterpret_cast<UINT_PTR>(visible.hwnd);
        foundHidden|=opened.entry.windows[i].hwnd==reinterpret_cast<UINT_PTR>(hidden.hwnd);
    }
    Check(foundVisible && !foundHidden,"app intent excludes already visible siblings as of mouse-down");
    cancel(0);
    Check(!intent(Messages.serial,&opened,sizeof(opened)),"another input invalidates the app intent");
    const unsigned after=Messages.compat;
    Check(press() && mouse(WM_LBUTTONUP,x+35,y),"simulate app drag without sending OS input");
    Drain();
    Check(Messages.compat==after,"application drag cannot publish an open-window intent");
}
void CheckPhysicalInput(HMODULE module,HWND candidate,const std::vector<HMONITOR>& monitors) {
    auto mouse=reinterpret_cast<BOOL(*)(unsigned,int,int)>(GetProcAddress(module,"TF_TestMouseInput"));
    auto publish=reinterpret_cast<BOOL(*)(const NativeEntry*,unsigned,unsigned)>(GetProcAddress(module,"TF_PublishCache"));
    auto status=reinterpret_cast<StatusFn>(GetProcAddress(module,"TF_Status"));
    auto input=reinterpret_cast<BOOL(*)(NativeInputStatus*,unsigned)>(GetProcAddress(module,"TF_InputStatus"));
    auto nextInput=reinterpret_cast<BOOL(*)(std::uint64_t,NativeInputStatus*,unsigned)>(GetProcAddress(module,"TF_NextInputStatus"));
    auto cancel=reinterpret_cast<CancelFn>(GetProcAddress(module,"TF_Cancel"));
    auto intent=reinterpret_cast<IntentFn>(GetProcAddress(module,"TF_CompatibilityIntent"));
    Check(mouse && publish && status && input && nextInput && cancel && intent,"physical input regression ABI");
    WNDCLASSW cls{}; cls.hInstance=GetModuleHandleW(nullptr); cls.lpfnWndProc=DefWindowProcW;
    cls.lpszClassName=L"Shell_SecondaryTrayWnd";
    Check(RegisterClassW(&cls)!=0,"register owned taskbar hit-test fixture");
    WNDCLASSW menuClass=cls; menuClass.lpszClassName=L"Windows.UI.Core.CoreWindow";
    Check(RegisterClassW(&menuClass)!=0,"register owned jump-list hit-test fixture");
    for (HMONITOR monitor:monitors) {
        const auto original=SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        MONITORINFO info{sizeof(info)};
        Check(GetMonitorInfoW(monitor,&info)!=FALSE,"physical input monitor geometry");
        HWND bar=CreateWindowExW(WS_EX_TOPMOST|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE,cls.lpszClassName,L"",WS_POPUP,
            info.rcMonitor.left+100,info.rcMonitor.bottom-100,400,80,nullptr,nullptr,cls.hInstance,nullptr);
        Check(bar!=nullptr,"create owned taskbar fixture on each monitor");
        struct WindowGuard { HWND hwnd; ~WindowGuard() { DestroyWindow(hwnd); } } ownedBar{bar};
        ShowWindow(bar,SW_SHOWNOACTIVATE);
        NativeEntry entry{};
        entry.taskbar=reinterpret_cast<UINT_PTR>(bar);
        Check(GetWindowRect(bar,&entry.button)!=FALSE,"read physical taskbar fixture rectangle");
        entry.count=1; entry.flags=TF_VERIFIED_FOLLOW;
        entry.windows[0]={reinterpret_cast<UINT_PTR>(candidate),GetCurrentProcessId(),0};
        GetModuleFileNameW(nullptr,entry.path,1024);
        wcscpy_s(entry.appId,L"TaskbarFollow.PhysicalInputFixture");
        const int x=(entry.button.left+entry.button.right)/2,y=(entry.button.top+entry.button.bottom)/2;
        Check(GetAncestor(WindowFromPoint({x,y}),GA_ROOT)==bar,"physical fixture is the actual hit-test target");
        SetThreadDpiAwarenessContext(original);
        for (const auto context : {DPI_AWARENESS_CONTEXT_UNAWARE,DPI_AWARENESS_CONTEXT_SYSTEM_AWARE,
            DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE,DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2}) {
            const auto previous=SetThreadDpiAwarenessContext(context);
            Check(previous!=nullptr,"set caller DPI context for input callback");
            NativeStatus before{},after{};
            NativeInputStatus prior{};
            Check(input(&prior,sizeof(prior))!=FALSE,"read diagnostic cursor before click");
            Check(publish(&entry,1,sizeof(entry))!=FALSE,"publish physical fixture button");
            Check(status(&before,sizeof(before))!=FALSE,"read before callback input status");
            Check(mouse(WM_LBUTTONDOWN,x,y)!=FALSE,"simulate owned mouse-down callback without sending input");
            Check(AreDpiAwarenessContextsEqual(GetThreadDpiAwarenessContext(),context)!=FALSE,"mouse-down restores caller DPI context");
            Check(mouse(WM_LBUTTONUP,x,y)!=FALSE,"simulate owned mouse-up callback without sending input");
            Check(AreDpiAwarenessContextsEqual(GetThreadDpiAwarenessContext(),context)!=FALSE,"mouse-up restores caller DPI context");
            Check(status(&after,sizeof(after)) && after.armed==before.armed+1,"physical click arms once from every caller DPI context");
            NativeInputStatus observation{};
            Check(input(&observation,sizeof(observation)) && observation.phase==2 && observation.reason==7
                && observation.awareness==DPI_AWARENESS_PER_MONITOR_AWARE && observation.root==entry.taskbar,
                "callback hit-test uses per-monitor physical coordinates");
            MONITORINFOEXW target{}; target.cbSize=sizeof(target);
            { const auto saved=SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
                Check(GetMonitorInfoW(monitor,&target)!=FALSE,"read callback target monitor");
                SetThreadDpiAwarenessContext(saved); }
            Check(wcscmp(after.target,target.szDevice)==0,"callback preserves the actual clicked monitor");
            Drain();
            NativeIntent click{};
            Check(intent(Messages.serial,&click,sizeof(click))!=FALSE,
                "after-show controller can read the physical click from every caller DPI context");
            NativeInputStatus press{},release{};
            Check(nextInput(prior.number,&press,sizeof(press)) && nextInput(press.number,&release,sizeof(release))
                && press.phase==1 && release.phase==2 && release.number==observation.number,
                "diagnostics preserve both halves of a quick click between polls");
            Check(press.point.x==x && press.point.y==y && wcscmp(press.target,target.szDevice)==0
                && wcscmp(release.target,target.szDevice)==0 && release.serial==click.serial,
                "diagnostics link the original physical point and target to the routed transaction");
            cancel(0);
            Check(status(&before,sizeof(before))!=FALSE,"read before drag rejection");
            Check(mouse(WM_LBUTTONDOWN,x,y) && mouse(WM_LBUTTONUP,x+30,y),"simulate owned taskbar drag");
            Check(status(&after,sizeof(after)) && before.armed==after.armed,"drag still does not arm positioning");
            Check(input(&observation,sizeof(observation)) && observation.reason==10,"diagnostics retain why drag was rejected");
            Check(mouse(WM_LBUTTONDOWN,x,y)!=FALSE,"begin cancellable owned input");
            cancel(0);
            Check(mouse(WM_LBUTTONUP,x,y)!=FALSE,"release cancelled owned input");
            Check(status(&after,sizeof(after)) && before.armed==after.armed,"another input epoch still cancels positioning");
            Check(input(&observation,sizeof(observation)) && observation.reason==8,"diagnostics retain input cancellation");
            SetThreadDpiAwarenessContext(previous);
        }
        const auto menuDpi=SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        const int menuX=x, menuY=entry.button.top-70;
        HWND menu=CreateWindowExW(WS_EX_TOPMOST|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE,menuClass.lpszClassName,L"",WS_POPUP,
            menuX-60,menuY-60,120,130,nullptr,nullptr,cls.hInstance,nullptr);
        Check(menu!=nullptr,"create owned popup above taskbar");
        WindowGuard ownedMenu{menu}; ShowWindow(menu,SW_SHOWNOACTIVATE);
        Check(GetAncestor(WindowFromPoint({menuX,menuY}),GA_ROOT)==menu,"popup is the physical hit-test target");
        SetThreadDpiAwarenessContext(menuDpi);
        const auto openMenu=[&] { return mouse(WM_RBUTTONDOWN,x,y) && mouse(WM_RBUTTONUP,x,y); };
        const auto selectMenu=[&] { return mouse(WM_LBUTTONDOWN,menuX,menuY) && mouse(WM_LBUTTONUP,menuX,menuY); };
        NativeStatus beforeMenu{},afterMenu{};
        Check(status(&beforeMenu,sizeof(beforeMenu)) && publish(&entry,1,sizeof(entry)),"publish before testing owned jump-list selection");
        Check(mouse(WM_LBUTTONDOWN,x,entry.button.top) && mouse(WM_LBUTTONUP,x,entry.button.top-1),
            "release across the edge of the taskbar while inside the drag tolerance");
        Check(status(&afterMenu,sizeof(afterMenu)) && beforeMenu.armed==afterMenu.armed,
            "a taskbar click released over another surface does not arm positioning");
        Check(SUCCEEDED(SetThreadDescription(GetCurrentThread(),L"RoutingTests")) && openMenu() && selectMenu(),"click another CoreWindow class instance");
        Check(status(&afterMenu,sizeof(afterMenu)) && beforeMenu.armed==afterMenu.armed,"CoreWindow class alone cannot arm a jump-list selection");
        Check(SUCCEEDED(SetThreadDescription(GetCurrentThread(),L"JumpViewUI")) && selectMenu(),"click jump-list-shaped popup without a matching right click");
        Check(status(&afterMenu,sizeof(afterMenu)) && beforeMenu.armed==afterMenu.armed,"a jump-list popup requires its taskbar context");
        const unsigned beforeMessage=Messages.compat;
        Check(openMenu() && status(&afterMenu,sizeof(afterMenu)) && beforeMenu.armed==afterMenu.armed,
            "right-clicking the app button never moves a window");
        Check(selectMenu(),"select from the opened jump list");
        Drain();
        NativeIntent selection{};
        Check(Messages.compat==beforeMessage+1 && intent(Messages.serial,&selection,sizeof(selection)),"menu selection posts an after-show intent");
        Check(selection.entry.flags==TF_JUMP_LIST && wcscmp(selection.entry.appId,entry.appId)==0
            && selection.source==reinterpret_cast<UINT_PTR>(menu) && selection.monitor==reinterpret_cast<UINT_PTR>(monitor),
            "jump-list selection retains the verified app identity and physical source monitor");
        NativeEntry compatible=entry;
        compatible.count=0; compatible.flags=TF_COLD_START|TF_COMPATIBILITY;
        Check(publish(&compatible,1,sizeof(compatible)) && openMenu() && selectMenu(),"select a verified x86 jump-list launch");
        Drain();
        Check(intent(Messages.serial,&selection,sizeof(selection))
            && selection.entry.flags==(TF_JUMP_LIST|TF_COLD_START|TF_COMPATIBILITY),
            "jump-list selection preserves the executable's after-show requirement");
        Check(status(&beforeMenu,sizeof(beforeMenu)) && openMenu(),"start a second owned menu interaction");
        cancel(0);
        Check(selectMenu() && status(&afterMenu,sizeof(afterMenu)) && beforeMenu.armed==afterMenu.armed,
            "an intervening input epoch invalidates the menu context");
        ShowWindow(menu,SW_HIDE);
        // A foreground window covering the taskbar must continue to prevent a
        // match, even when its coordinates overlap a valid cached button.
        const auto saved=SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        HWND cover=CreateWindowExW(WS_EX_TOPMOST|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE,L"TaskbarFollow.RoutingFixture",L"",WS_POPUP,
            entry.button.left,entry.button.top,400,80,nullptr,nullptr,cls.hInstance,nullptr);
        Check(cover!=nullptr,"create owned occluding window");
        WindowGuard ownedCover{cover}; ShowWindow(cover,SW_SHOWNOACTIVATE);
        SetThreadDpiAwarenessContext(saved);
        NativeStatus before{},after{};
        Check(status(&before,sizeof(before))!=FALSE,"read before occluded click");
        Check(publish(&entry,1,sizeof(entry)) && mouse(WM_LBUTTONDOWN,x,y) && mouse(WM_LBUTTONUP,x,y),"simulate owned occluded click");
        Check(status(&after,sizeof(after)) && before.armed==after.armed,"occluded taskbar is not treated as clicked");
        NativeInputStatus observation{};
        Check(input(&observation,sizeof(observation)) && observation.reason==4,"diagnostics retain rejected physical hits");
    }
}
}
int wmain(int argc,wchar_t** argv) {
    const HDESK original=GetThreadDesktop(GetCurrentThreadId());
    const std::wstring name=L"TaskbarFollow.RoutingTests."+std::to_wstring(GetCurrentProcessId());
    HDESK desktop=CreateDesktopW(name.c_str(),nullptr,nullptr,0,GENERIC_ALL,nullptr);
    if (!desktop || !SetThreadDesktop(desktop)) { fputs("FAIL routing desktop\n",stderr); return 1; }
    HMODULE module{}; HWND receiver{},statusWindow{}; StopFn stop{}; int result=0;
    try {
        Check(argc==2,"pass the native routing DLL path");
        WNDCLASSW cls{}; cls.hInstance=GetModuleHandleW(nullptr); cls.lpfnWndProc=Receive;
        cls.lpszClassName=L"TaskbarFollow.RoutingFixture";
        Check(RegisterClassW(&cls)!=0,"register owned routing window class");
        receiver=CreateWindowExW(0,cls.lpszClassName,L"",0,0,0,0,0,HWND_MESSAGE,nullptr,cls.hInstance,nullptr);
        statusWindow=CreateWindowExW(WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE,cls.lpszClassName,L"",WS_OVERLAPPEDWINDOW,
            0,0,640,400,nullptr,nullptr,cls.hInstance,nullptr);
        Check(receiver && statusWindow,"create hidden owned routing windows");
        module=LoadLibraryW(argv[1]); Check(module!=nullptr,"load routing DLL");
        auto start=reinterpret_cast<StartFn>(GetProcAddress(module,"TF_Start"));
        stop=reinterpret_cast<StopFn>(GetProcAddress(module,"TF_StopAndWait"));
        auto release=reinterpret_cast<ReleaseFn>(GetProcAddress(module,"TF_TestReleaseEntry"));
        auto intent=reinterpret_cast<IntentFn>(GetProcAddress(module,"TF_CompatibilityIntent"));
        auto cancel=reinterpret_cast<CancelFn>(GetProcAddress(module,"TF_Cancel"));
        auto cancelCompatibility=reinterpret_cast<CancelCompatibilityFn>(GetProcAddress(module,"TF_CancelCompatibility"));
        auto enable=reinterpret_cast<EnableFn>(GetProcAddress(module,"TF_SetEnabled"));
        auto status=reinterpret_cast<StatusFn>(GetProcAddress(module,"TF_Status"));
        auto shellLaunch=reinterpret_cast<BOOL(*)(HWND,HMONITOR)>(GetProcAddress(module,"TF_TestShellLaunch"));
        auto intentBytes=reinterpret_cast<unsigned(*)()>(GetProcAddress(module,"TF_IntentBytes"));
        auto takeover=reinterpret_cast<BOOL(*)(unsigned)>(GetProcAddress(module,"TF_BeginFallback"));
        Check(intentBytes && intentBytes()==sizeof(NativeIntent),"controller can reject an incompatible intent ABI before startup");
        Check(start && stop && release && intent && cancel && cancelCompatibility && enable && status,"routing ABI is present");
        std::vector<HMONITOR> monitors; EnumDisplayMonitors(nullptr,nullptr,Collect,reinterpret_cast<LPARAM>(&monitors));
        Check(!monitors.empty(),"at least one monitor is available");
        const HMONITOR target=monitors.back();
        Check(start(receiver,TF_TEST_MODE)!=FALSE,"start input-free routing controller");
        NativeEntry entry{}; GetModuleFileNameW(nullptr,entry.path,1024);
        wcscpy_s(entry.appId,L"TaskbarFollow.Status");
        entry.count=1; entry.windows[0]={reinterpret_cast<UINT_PTR>(statusWindow),GetCurrentProcessId(),0};
        Check(release(&entry,target,FALSE)!=FALSE,"verified own status entry is routed");
        Wait([] {return Messages.own==1;});
        Check(Messages.window==statusWindow && Messages.monitor==target,"own status message retains exact HWND and target");
        NativeStatus state{};
        Check(status(&state,sizeof(state)) && state.armed==0,"own status click does not arm a generic positioning transaction");

        entry.windows[0].pid+=1;
        Check(!release(&entry,target,FALSE),"stale candidate PID is rejected");
        entry.windows[0].pid=GetCurrentProcessId();
        wcscpy_s(entry.appId,L"Other.ExactIdentity");
        Check(release(&entry,target,FALSE)!=FALSE,"other owned test identity uses normal routing");
        Drain(); Check(Messages.own==1,"another identity cannot trigger status self-follow"); cancel(0);

        wcscpy_s(entry.appId,L"TaskbarFollow.CompatibilityFixture");
        entry.count=0; entry.flags=TF_COLD_START|TF_COMPATIBILITY;
        const unsigned previous=Messages.compat;
        Check(release(&entry,target,FALSE)!=FALSE,"verified compatibility click is routed");
        Wait([&] {return Messages.compat==previous+1;});
        NativeIntent snapshot{};
        Check(Messages.monitor==target && intent(Messages.serial,&snapshot,sizeof(snapshot)),"compatibility message has a readable matching intent");
        Check(snapshot.serial==Messages.serial && snapshot.monitor==reinterpret_cast<UINT_PTR>(target),"snapshot preserves serial and target");
        Check(snapshot.entry.flags==(TF_COLD_START|TF_COMPATIBILITY) && snapshot.entry.count==0,"cold compatibility identity is preserved");
        Check(wcscmp(snapshot.entry.path,entry.path)==0 && snapshot.expires>snapshot.released,"snapshot contains verified executable and bounded lifetime");
        Check(!intent(Messages.serial+1,&snapshot,sizeof(snapshot)),"wrong serial cannot read another click");
        Check(!intent(Messages.serial,&snapshot,sizeof(snapshot)-1),"incorrect ABI size is rejected");
        cancel(0); Check(!intent(Messages.serial,&snapshot,sizeof(snapshot)),"new-input epoch cancellation invalidates a pending compatibility click");

        const unsigned replacedSerial=Messages.serial, beforeReplacement=Messages.compat;
        Check(release(&entry,target,FALSE)!=FALSE,"replacement compatibility click is armed");
        Wait([&] {return Messages.compat==beforeReplacement+1;});
        const unsigned replacementSerial=Messages.serial;
        Check(replacementSerial!=replacedSerial && !cancelCompatibility(replacedSerial),"stale compatibility serial cannot cancel its replacement");
        Check(intent(replacementSerial,&snapshot,sizeof(snapshot)),"replacement compatibility intent survives stale cancellation");
        Check(cancelCompatibility(replacementSerial)!=FALSE,"matching compatibility serial cancels its own intent");
        Check(!intent(replacementSerial,&snapshot,sizeof(snapshot)) && !cancelCompatibility(replacementSerial),"compatibility cancellation cannot be replayed");

        const unsigned beforePause=Messages.compat;
        Check(release(&entry,target,FALSE)!=FALSE,"second compatibility click is armed");
        Wait([&] {return Messages.compat==beforePause+1;});
        enable(FALSE); Check(!intent(Messages.serial,&snapshot,sizeof(snapshot)),"pause invalidates the compatibility route");
        enable(TRUE);
        entry.count=2;
        entry.windows[0]={reinterpret_cast<UINT_PTR>(statusWindow),GetCurrentProcessId(),0};
        entry.windows[1]=entry.windows[0];
        const unsigned beforeGroup=Messages.compat;
        Check(release(&entry,target,FALSE)!=FALSE,"group button is recognized without choosing a window");
        Drain(); Check(Messages.compat==beforeGroup,"unselected group cannot trigger compatibility positioning");
        Check(status(&state,sizeof(state)) && state.lastKind==TF_GROUP,"unselected group retains selection feedback");
        Check(release(&entry,target,TRUE)!=FALSE,"explicit thumbnail selection arms compatibility routing");
        Wait([&] {return Messages.compat==beforeGroup+1;});
        Check(intent(Messages.serial,&snapshot,sizeof(snapshot)) && snapshot.entry.count==2,"selected group retains verified candidate identities");
        cancel(0);

        entry.count=0; entry.flags=TF_COLD_START|TF_REQUIRE_APP_ID|TF_PACKAGED_FOLLOW;
        wcscpy_s(entry.appId,L"TaskbarFollow.PackageFixture_0000000000000!App");
        const unsigned beforePackage=Messages.compat;
        Check(release(&entry,target,FALSE)!=FALSE,"packaged launch arms native and after-show routing");
        Wait([&] {return Messages.compat==beforePackage+1;});
        Check(intent(Messages.serial,&snapshot,sizeof(snapshot)) && snapshot.entry.flags==entry.flags && !snapshot.nativeClaimed,
            "packaged launch exposes its exact flags and initially unclaimed state");
        Check(cancelCompatibility(Messages.serial)!=FALSE,"a packaged follow can end its own intent after confirmation");
        entry.flags=TF_VERIFIED_FOLLOW; entry.count=1;
        entry.windows[0]={reinterpret_cast<UINT_PTR>(statusWindow),GetCurrentProcessId(),0};
        const unsigned beforeVerified=Messages.compat;
        Check(release(&entry,target,FALSE)!=FALSE,"any verified existing window can request bounded backup");
        Wait([&] {return Messages.compat==beforeVerified+1;});
        Check(intent(Messages.serial,&snapshot,sizeof(snapshot)) && snapshot.entry.count==1
            && snapshot.entry.windows[0].hwnd==reinterpret_cast<UINT_PTR>(statusWindow),"verified backup retains exact HWND/PID");
        Check(takeover && takeover(Messages.serial),"backup atomically takes ownership of its matching serial");
        Check(intent(Messages.serial,&snapshot,sizeof(snapshot)),"handoff preserves the live intent for target verification and input cancellation");
        Check(!takeover(Messages.serial+1),"a different serial cannot take over this click");
        cancel(0);
        Check(!takeover(Messages.serial),"new input invalidates an uncompleted fallback takeover");
        Check(shellLaunch!=nullptr,"shell launch test interface is available");
        const unsigned beforeShell=Messages.compat;
        Check(shellLaunch(statusWindow,target)!=FALSE,"explicit owned shell-launch path posts a bounded intent");
        Wait([&] {return Messages.compat==beforeShell+1;});
        Check(intent(Messages.serial,&snapshot,sizeof(snapshot)) && snapshot.entry.flags==TF_SHELL_LAUNCH
            && snapshot.entry.count==0 && !snapshot.entry.path[0] && !snapshot.entry.appId[0],"shell origin does not invent a target application identity");
        Check(snapshot.before==reinterpret_cast<UINT_PTR>(statusWindow) && snapshot.source==snapshot.before
            && snapshot.expires-snapshot.released==2000,"shell launch preserves origin HWND and its two-second expiry");
        cancel(0); Check(!intent(Messages.serial,&snapshot,sizeof(snapshot)),"another input cancels shell-origin routing");
        Check(!shellLaunch(nullptr,target),"a missing/unowned shell source cannot be armed in test mode");
        entry.count=0; entry.flags=0;
        Check(!release(&entry,target,FALSE),"unverified no-window button remains unsupported");
        wcscpy_s(entry.path,L"C:\\not-the-test-executable.exe"); entry.flags=TF_COLD_START|TF_COMPATIBILITY;
        Check(!release(&entry,target,FALSE),"test route cannot target an unrelated executable");
        CheckPhysicalInput(module,statusWindow,monitors);
        CheckAppInput(module,target);
        Check(stop(3000)!=FALSE,"routing controller joins before resource release");
        Check(!intent(Messages.serial,&snapshot,sizeof(snapshot)),"a stopped controller exposes no stale intent");
        printf("PASS %u native explicit-click/self-window/compatibility routing assertions; no input hooks\n",Checks);
    } catch (const std::exception& error) {
        fprintf(stderr,"FAIL native routing: %s; Win32=%lu\n",error.what(),GetLastError()); result=1;
    }
    if (module && (!stop || stop(3000))) FreeLibrary(module);
    if (statusWindow) DestroyWindow(statusWindow);
    if (receiver) DestroyWindow(receiver);
    if (SetThreadDesktop(original)) CloseDesktop(desktop);
    return result;
}
