program bench_stream;

{$mode delphi}{$H+}
{$B-}

uses Windows, SysUtils, Classes, Math, uLargeJson, listplug;

type TProcessMemoryCountersEx = record
  cb, PageFaultCount: DWORD;
  PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage,
    QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage,
    PrivateUsage: PtrUInt;
end;
function GetProcessMemoryInfo(Process: THandle; Data: Pointer; Size: DWORD): BOOL; stdcall; external 'psapi.dll';

var W: TLargeWorker;
    Q: TLargeQuery;
    S: TLargeSnapshot;
    Expected, Row, Clock, Timeout, Peak, Disk: Int64;

procedure Check(Cond: Boolean; const MessageText: String);
begin
  if not Cond then raise Exception.Create(MessageText);
end;

procedure Poll;
var Info: TProcessMemoryCountersEx;
begin
  S := W.Snapshot;
  if (S.Status and StatusError) <> 0 then raise Exception.Create(S.Error);
  Info.cb := SizeOf(Info);
  if GetProcessMemoryInfo(GetCurrentProcess, @Info, SizeOf(Info)) then
    Peak := Max(Peak, Int64(Info.PrivateUsage));
  Disk := Max(Disk, S.DiskBytes);
  Check(GetTickCount64 < QWord(Timeout), 'timed out');
  Sleep(5);
end;

procedure RequestPage(Target: Int64);
begin
  Inc(Q.Ticket);
  Q.PageStart := Target;
  W.Request(Q);
  Clock := GetTickCount64;
  repeat Poll until (S.Ticket = Q.Ticket) and (S.Page.First = Target) and (Length(S.Page.Rows) > 0);
  Check(S.Page.Rows[0][0] = IntToStr(Target),'jump wrong row');
  WriteLn('jump=',Target,' ms=', GetTickCount64-Clock,' cache=',S.CacheBytes);
  Flush(Output);
end;

begin
  Expected := StrToInt64(ParamStr(2));
  W := TLargeWorker.Create(UnicodeString(ParamStr(1)));
  try
    Q.TextRow := -2;
    Q.Ticket := 1;
    W.Request(Q);
    Clock := GetTickCount64;
    Timeout := Clock + 900000;
    repeat Poll until Length(S.Page.Rows) > 0;
    WriteLn('first_ms=', GetTickCount64-Clock, ' indexed_at_first=', S.TotalRows);
    Flush(Output);
    repeat Poll until (S.Status and StatusIndexDone) <> 0;
    Check((S.TotalRows = Expected) and (S.FieldCount = 8), 'index totals');
    WriteLn('index_ms=', S.IndexMS,' at100_ms=', S.At100MS, ' rows=',S.TotalRows,' fields=',S.FieldCount,' disk=',S.DiskBytes);
    Flush(Output);
    RequestPage(Expected div 2);
    RequestPage(Expected - 1);
    RequestPage(0);
    Inc(Q.Revision);
    Inc(Q.Ticket);
    Q.Grouping := True;
    Q.GroupField := 'session';
    W.Request(Q);
    repeat Poll until (S.Revision = Q.Revision) and ((S.Status and StatusGroupDone) <> 0);
    Check((S.Groups = 64) and (S.GroupItems[0].Count = Expected div 64), 'group totals');
    WriteLn('group_ms=', S.GroupMS, ' groups=',S.Groups,' selected_group_count=',S.GroupItems[0].Count,' disk=',S.DiskBytes);
    Flush(Output);
    Inc(Q.Revision);
    Inc(Q.Ticket);
    Q.GroupId := S.GroupItems[0].Id;
    SetLength(Q.Filters, 1);
    Q.Filters[0].Field := 'late';
    Q.Filters[0].Pattern := '=needle';
    W.Request(Q);
    repeat Poll until (S.Revision = Q.Revision) and ((S.Status and StatusFilterDone) <> 0);
    Check(S.Rows = 1, 'grouped filtering totals');
    WriteLn('filter_group_ms=', S.FilterMS,' filtered_count=',S.Rows);
    Flush(Output);
    Inc(Q.Revision);
    Inc(Q.Ticket);
    Q.Grouping := False;
    Q.GroupField := '';
    Q.GroupId := 0;
    W.Request(Q);
    repeat Poll until (S.Revision = Q.Revision) and ((S.Status and StatusFilterDone) <> 0);
    Check(S.Rows = 64, 'full filtering totals');
    WriteLn('filter_all_ms=', S.FilterMS,' filtered_count=',S.Rows);
    Flush(Output);
    Inc(Q.FindTicket);
    Q.FindText := 'needle';
    Q.FindFlags := lcs_findfirst;
    Q.FindFrom := 0;
    W.Request(Q);
    repeat Poll until (S.FindTicket = Q.FindTicket) and ((S.Status and StatusSearchDone) <> 0);
    Check(S.FoundRow = 0, 'find within result');
    WriteLn('peak_private=', Peak, ' peak_index_disk=',Disk);
  finally
    W.Free;
  end;
end.
