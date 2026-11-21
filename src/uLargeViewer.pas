unit uLargeViewer;

{$mode delphi}{$H+}
{$B-}
{$codepage utf8}

interface

uses Windows;

function IsLargeViewer(Wnd: HWND): Boolean;
function LargeFileThreshold(out Limit: Int64): Boolean;
function CreateLargeViewer(Parent: HWND; const FileName: UnicodeString;
  Size: Int64; ShowFlags: Integer): HWND;
procedure CloseLargeViewer(Wnd: HWND);
procedure SetLargeShowFlags(Wnd: HWND; Flags: Integer);
function SearchLargeViewer(Wnd: HWND; const Text: UnicodeString; Flags: Integer): Integer;

implementation

uses Classes, SysUtils, Math, Messages, CommCtrl, RichEdit, listplug, uSettings,
  uLargeJson, uJsonStream, uRichEditRanges, uViewerControls, uSettingsDialog, uLocale;

const
  ViewerClass = 'JsonTabStreamingViewer';
  GridID = 101;
  TreeID = 102;
  TextID = 103;
  TabsID = 104;
  StatusID = 105;
  PrevID = 111;
  NextID = 112;
  PrevGroupID = 114;
  NextGroupID = 115;
  PrevColumnID = 116;
  NextColumnID = 117;
  GridBudget = 24 * 1024 * 1024;
  RefreshTimer = 1;
  FilterTimer = 2;
  Ellipsis = '…';
  ViewRows = 100000000;

type
  PLargeListInfo = ^TLargeListInfo;
  TLargeListInfo = record
    Hdr: NMHDR;
    Item: TLVItemW;
  end;
  PLargeCacheHint = ^TLargeCacheHint;
  TLargeCacheHint = record
    Hdr: NMHDR;
    First, Last: Integer;
  end;
  TPagePositions = array of Int64;
  TLargeViewer = class
    FWnd, FGrid, FTree, FText, FTabs, FStatus: HWND;
    FChrome: TViewerChrome;
    FPrev, FNext, FPrevGroup, FNextGroup: HWND;
    FPrevColumn, FNextColumn: HWND;
    FWorker: TLargeWorker;
    FState: TLargeSnapshot;
    FQuery: TLargeQuery;
    FCache: array of TLargePage;
    FWidths: TStringList;
    FSlots: array of HTREEITEM;
    FSlotCaptions: array of UnicodeString;
    FTitle: HTREEITEM;
    FTextHistory: TPagePositions;
    FLastFind: Int64;
    FNeedPage, FWasRequested: Int64;
    FTextTicket, FFindTicket, FGeneration: Integer;
    FLastRows, FGridBase: Int64;
    FGroupOption: UTF8String;
    FHasGroupOption: Boolean;
    FFirstShown, FInTree, FInColumns, FDark: Boolean;
    FBrush, FFilterBrush: HBRUSH;
    FBackColor, FTextColor, FFilterBackColor, FFilterTextColor, FBorderColor: COLORREF;
    FUpdatingPattern, FFilterPending: Boolean;
    FPendingField: UTF8String;
    FPendingValue: UnicodeString;
    FFont, FDataFont: HFONT;
    FTextDocument: ITextDocument;
    FShowFlags: Integer;
    FHighlighting, FUseBold, FClosing: Boolean;
    FFirstColored, FLastColored: Integer;
    FJsonTextColor, FKeyColor, FStringColor, FBooleanColor, FNullColor: COLORREF;
    FRichEdit: HMODULE;
    FRecordNodes: array of HTREEITEM;
    FNodeParent: HTREEITEM;
    FNodeStart, FShownGroup: Int64;
    FNodeCount: Integer;
    procedure AddControl(var Handle: HWND; Kind: PWideChar; const Caption: UnicodeString;
      Id: Integer; Style: DWORD; ExStyle: DWORD = 0);
    procedure PrepareControl(Handle: HWND; Keyboard: Boolean);
    procedure Layout;
    procedure ApplyTheme;
    procedure ApplyTextPalette;
    procedure ApplyFont;
    procedure OpenSettings;
    function ControlMessage(Wnd: HWND; Msg: UINT; W: WPARAM; L: LPARAM;
      out AResult: LRESULT): Boolean;
    procedure PaintChrome(Wnd: HWND; DC: HDC);
    procedure RequestView;
    procedure RequestPage(AtRow: Int64);
    procedure RequestText;
    procedure TextPage(Step: Integer);
    procedure UpdateColumns(const NewState: TLargeSnapshot);
    procedure UpdateTree(const NewState: TLargeSnapshot);
    procedure UpdateRecordNodes(Count: Int64);
    procedure ClearRecordNodes;
    procedure UpdateSnapshot;
    procedure UpdateStatus;
    procedure SetGridPosition(Row: Int64; Select: Boolean);
    procedure UpdateGridCount;
    procedure CachePage(const Page: TLargePage);
    function ReadCell(Row: Int64; Col: Integer): UnicodeString;
    function SelectedGridRow: Int64;
    procedure SetGroupField;
    procedure SetGroup(Id: Int64);
    function SelectedFilterField(out Name: UTF8String): Boolean;
    procedure SyncFilterEditor(const Name: UTF8String);
    procedure QueueFilter;
    procedure ApplyPendingFilter;
    procedure ClearFilters;
    procedure TreeSelected;
    procedure ChangeTab;
    procedure MarkText;
    procedure ContextMenu(Source: HWND; X, Y: Integer);
    procedure CopyView;
    function DoSearch(const Text: UnicodeString; Flags: Integer): Integer;
    function Dispatch(Msg: UINT; W: WPARAM; L: LPARAM): LRESULT;
    constructor Create(Parent: HWND; const FileName: UnicodeString; Flags: Integer);
    destructor Destroy; override;
  end;

function SetWindowTheme(Wnd: HWND; SubApp, SubId: PWideChar): HRESULT;
  stdcall; external 'uxtheme.dll';

function LargeControlProc(Wnd: HWND; Msg: UINT; W: WPARAM; L: LPARAM;
  Id, RefData: PtrUInt): LRESULT; stdcall;
begin
  if Msg = WM_NCDESTROY then RemoveWindowSubclass(Wnd, @LargeControlProc, Id)
  else if TLargeViewer(RefData).ControlMessage(Wnd, Msg, W, L, Result) then Exit;
  Result := DefSubclassProc(Wnd, Msg, W, L);
end;

function LargeFileThreshold(out Limit: Int64): Boolean;
var Old: UnicodeString;
begin
  if not TryStrToInt64(Trim(ReadSetting('full-load-max-size', '')), Limit) or (Limit <= 0) then
  begin
    Old := ReadSetting('max-file-size', 'missing');
    if Old <> 'missing' then
    begin
      Limit := StrToIntDef(Old, 1000000);
      Exit(False);
    end;
    Limit := 5 * 1024 * 1024;
  end;
  Result := True;
end;

{$push}{$packrecords c}
type
  TConfirmButton = record
    Id: Integer;
    Text: PWideChar;
  end;
  TConfirmDialog = record
    Size: UINT;
    Parent: HWND;
    Instance: HINST;
    Flags, CommonButtons: DWORD;
    WindowTitle, MainIcon, MainInstruction, Content: PWideChar;
    ButtonCount: UINT;
    Buttons: ^TConfirmButton;
    DefaultButton: Integer;
    RadioCount: UINT;
    RadioButtons: Pointer;
    DefaultRadio: Integer;
    Verification, Expanded, ExpandedControl, CollapsedControl, FooterIcon, Footer: PWideChar;
    Callback: Pointer;
    CallbackData: PtrInt;
    Width: UINT;
  end;
{$pop}

function AllowedToOpen(Parent: HWND; Size: Int64): Boolean;
var Warning: Int64;
    Caption, Prompt, Detail: UnicodeString;
    Buttons: array[0..1] of TConfirmButton;
    Dialog: TConfirmDialog;
    CommonControls: HMODULE;
    ShowDialog: function(constref Config: TConfirmDialog; Button, Radio: PInteger;
      Verification: PBOOL): HRESULT; stdcall;
    Chosen: Integer;
    OpenText, CancelText: UnicodeString;
begin
  if not TryStrToInt64(Trim(ReadSetting('large-file-warning-size', '')), Warning) or
    (Warning <= 0) then Warning := 1073741824;
  if Size < Warning then Exit(True);
  Caption := Tr('Large JSON file', 'Большой файл JSON');
  Prompt := UnicodeFormat(Tr('File size: %s MiB (%s bytes).',
    'Размер файла: %s МиБ (%s байт).'),
    [FormatFloat('0.00', Size / 1048576), IntToStr(Size)]);
  Detail := Tr('The file will load in parts. Some fields may be unavailable for grouping and filtering during indexing.',
    'Файл будет загружаться по частям. При индексации некоторые поля могут быть недоступны для группировки и фильтрации.');
  CommonControls := GetModuleHandleW('comctl32.dll');
  PPointer(@@ShowDialog)^ := GetProcAddress(CommonControls, 'TaskDialogIndirect');
  if Assigned(ShowDialog) then
  begin
    Buttons[0].Id := IDOK;
    OpenText := Tr('Open', 'Открыть');
    Buttons[0].Text := PWideChar(OpenText);
    Buttons[1].Id := IDCANCEL;
    CancelText := Tr('Cancel', 'Отмена');
    Buttons[1].Text := PWideChar(CancelText);
    Dialog := Default(TConfirmDialog);
    Dialog.Size := SizeOf(Dialog);
    Dialog.Parent := Parent;
    Dialog.Flags := $0008; // TDF_ALLOW_DIALOG_CANCELLATION
    Dialog.WindowTitle := PWideChar(Caption);
    Dialog.MainInstruction := PWideChar(Prompt);
    Dialog.Content := PWideChar(Detail);
    Dialog.ButtonCount := Length(Buttons);
    Dialog.Buttons := @Buttons[0];
    Dialog.DefaultButton := IDCANCEL;
    if Succeeded(ShowDialog(Dialog, @Chosen, nil, nil)) then Exit(Chosen = IDOK);
  end;
  Prompt := Prompt + #13#10#13#10 + Detail;
  Result := MessageBoxW(Parent, PWideChar(Prompt), PWideChar(Caption),
    MB_OKCANCEL or MB_ICONINFORMATION or MB_DEFBUTTON2) = IDOK;
end;

function ViewerProc(Wnd: HWND; Msg: UINT; W: WPARAM; L: LPARAM): LRESULT; stdcall;
var Viewer: TLargeViewer;
begin
  if Msg = WM_NCCREATE then
    SetWindowLongPtrW(Wnd, GWLP_USERDATA, PtrInt(PCreateStruct(L)^.lpCreateParams));
  Viewer := TLargeViewer(GetWindowLongPtrW(Wnd, GWLP_USERDATA));
  if Viewer = nil then Exit(DefWindowProcW(Wnd, Msg, W, L));
  if Msg = WM_NCCREATE then Viewer.FWnd := Wnd;
  if Msg = WM_NCDESTROY then
  begin
    SetWindowLongPtrW(Wnd, GWLP_USERDATA, 0);
    Viewer.FWnd := 0;
    Result := DefWindowProcW(Wnd, Msg, W, L);
    if not Viewer.FClosing then Viewer.Free;
    Exit;
  end;
  try
    Result := Viewer.Dispatch(Msg, W, L);
  except
    on E: Exception do
    begin
      if Viewer.FStatus <> 0 then SetWindowTextW(Viewer.FStatus, PWideChar(ViewerErrorText(E)));
      Result := 0;
    end;
  end;
end;

procedure RegisterViewerClass;
var WC: TWndClassW;
begin
  if GetClassInfoW(HInstance, ViewerClass, @WC) then Exit;
  WC := Default(TWndClassW);
  WC.hInstance := HInstance;
  WC.lpszClassName := ViewerClass;
  WC.lpfnWndProc := @ViewerProc;
  WC.hCursor := LoadCursor(0, IDC_ARROW);
  if (RegisterClassW(WC) = 0) and (GetLastError <> ERROR_CLASS_ALREADY_EXISTS) then RaiseLastOSError;
end;

function ClassIsLarge(Wnd: HWND): Boolean;
var Name: array[0..63] of WideChar;
begin
  Result := (GetClassNameW(Wnd, @Name[0], Length(Name)) <> 0) and
    (UnicodeString(PWideChar(@Name[0])) = ViewerClass);
end;

function IsLargeViewer(Wnd: HWND): Boolean;
begin
  Result := ClassIsLarge(Wnd);
end;

function ChildText(Wnd: HWND): UnicodeString;
begin
  SetLength(Result, GetWindowTextLengthW(Wnd));
  if Result <> '' then GetWindowTextW(Wnd, PWideChar(Result), Length(Result) + 1);
end;

function ComboAdd(Wnd: HWND; const Name: UnicodeString): LRESULT;
begin
  Result := SendMessageW(Wnd, CB_ADDSTRING, 0, LPARAM(PWideChar(Name)));
end;

function TreeAdd(Wnd: HWND; Parent: HTREEITEM; const Caption: UnicodeString; Data: LPARAM): HTREEITEM;
var Item: TTVInsertStructW;
begin
  Item := Default(TTVInsertStructW);
  Item.hParent := Parent;
  Item.hInsertAfter := TVI_LAST;
  Item.item.mask := TVIF_TEXT or TVIF_PARAM;
  Item.item.pszText := PWideChar(Caption);
  Item.item.lParam := Data;
  Result := HTREEITEM(SendMessageW(Wnd, TVM_INSERTITEMW, 0, LPARAM(@Item)));
end;

procedure TLargeViewer.AddControl(var Handle: HWND; Kind: PWideChar;
  const Caption: UnicodeString; Id: Integer; Style: DWORD; ExStyle: DWORD);
begin
  Handle := CreateWindowExW(ExStyle, Kind, PWideChar(Caption), WS_CHILD or WS_VISIBLE or
    Style, 0, 0, 0, 0, FWnd, HMENU(Id), HInstance, nil);
  PrepareControl(Handle, (Style and WS_TABSTOP) <> 0);
end;

procedure TLargeViewer.PrepareControl(Handle: HWND; Keyboard: Boolean);
begin
  if Handle = 0 then RaiseLastOSError;
  if Keyboard and
    not SetWindowSubclass(Handle, @LargeControlProc, 0, PtrUInt(Self)) then
    RaiseLastOSError;
  SendMessageW(Handle, WM_SETFONT, WPARAM(FFont), 0);
end;

constructor TLargeViewer.Create(Parent: HWND; const FileName: UnicodeString; Flags: Integer);
var Init: TInitCommonControlsEx;
begin
  inherited Create;
  FShowFlags := Flags;
  FQuery.TextRow := -2;
  FQuery.CaseSensitive := ReadSettingInt('filter-case-sensitive', 0) <> 0;
  FLastFind := -1;
  FNeedPage := -1;
  FWasRequested := -1;
  FTextTicket := -1;
  FFirstColored := -1;
  FWidths := TStringList.Create;
  FWidths.CaseSensitive := True;
  FFont := GetStockObject(DEFAULT_GUI_FONT);
  Init.dwSize := SizeOf(Init);
  Init.dwICC := ICC_WIN95_CLASSES;
  InitCommonControlsEx(Init);
  FRichEdit := LoadLibraryW('Msftedit.dll');
  if FRichEdit = 0 then RaiseLastOSError;
  RegisterViewerClass;
  FWnd := CreateWindowExW(WS_EX_CONTROLPARENT, ViewerClass, '', WS_CHILD or WS_VISIBLE or
    WS_CLIPCHILDREN, 0, 0, 0, 0, Parent, 0, HInstance, Self);
  if FWnd = 0 then RaiseLastOSError;
  AddControl(FStatus, 'STATIC', Tr('Indexing...', 'Индексация…'), StatusID, SS_LEFTNOWORDWRAP);
  CreateViewerChrome(FWnd, FChrome, FFont);
  PrepareControl(FChrome.GroupBy, True);
  PrepareControl(FChrome.Field, True);
  PrepareControl(FChrome.Pattern, True);
  PrepareControl(FChrome.Clear, True);
  PrepareControl(FChrome.Refresh, True);
  PrepareControl(FChrome.Settings, True);
  FTree := CreateViewerTree(FWnd, TreeID);
  PrepareControl(FTree, True);
  AddControl(FPrevGroup, 'BUTTON', Tr('< Groups', '< Группы'), PrevGroupID, WS_TABSTOP);
  AddControl(FNextGroup, 'BUTTON', Tr('Groups >', 'Группы >'), NextGroupID, WS_TABSTOP);
  FTabs := CreateViewerTabs(FWnd, TabsID, TCS_BUTTONS);
  PrepareControl(FTabs, True);
  AddControl(FPrev, 'BUTTON', Tr('Previous', 'Назад'), PrevID, WS_TABSTOP);
  AddControl(FNext, 'BUTTON', Tr('Next', 'Далее'), NextID, WS_TABSTOP);
  AddControl(FPrevColumn, 'BUTTON', Tr('< Fields', '< Поля'), PrevColumnID, WS_TABSTOP);
  AddControl(FNextColumn, 'BUTTON', Tr('Fields >', 'Поля >'), NextColumnID, WS_TABSTOP);
  FGrid := CreateViewerGrid(FWnd, GridID, LVS_SINGLESEL or LVS_NOSORTHEADER);
  PrepareControl(FGrid, True);
  ListView_SetExtendedListViewStyle(FGrid, LVS_EX_FULLROWSELECT or LVS_EX_DOUBLEBUFFER or LVS_EX_HEADERDRAGDROP);
  FText := CreateViewerText(FWnd, TextID);
  PrepareControl(FText, True);
  SendMessageW(FText, EM_EXLIMITTEXT, 0, 2 * LargePreviewBytes);
  FTextDocument := RichEditDocument(FText);
  ShowWindow(FText, SW_HIDE);
  FTitle := TreeAdd(FTree, TVI_ROOT, Tr('<<root>>', '<<корень>>'), 0);
  FNodeStart := -1;
  EnableWindow(FChrome.GroupBy, False);
  Layout;
  ApplyFont;
  ApplyTheme;
  FWorker := TLargeWorker.Create(FileName);
  RequestView;
  SetTimer(FWnd, RefreshTimer, 25, nil);
end;

destructor TLargeViewer.Destroy;
begin
  FClosing := True;
  if FWnd <> 0 then
  begin
    KillTimer(FWnd, RefreshTimer);
    KillTimer(FWnd, FilterTimer);
  end;
  FWorker.Free;
  FTextDocument := nil;
  if FWnd <> 0 then DestroyWindow(FWnd);
  FWidths.Free;
  if FDataFont <> 0 then DeleteObject(FDataFont);
  if FBrush <> 0 then DeleteObject(FBrush);
  if FFilterBrush <> 0 then DeleteObject(FFilterBrush);
  if FRichEdit <> 0 then FreeLibrary(FRichEdit);
  inherited;
end;

procedure TLargeViewer.Layout;
var R: TRect;
    L: TViewerLayout;
    NavTop, GroupWidth, NavWidth, NavHeight, BodyTop: Integer;
    TextTab: Boolean;
  procedure Place(C: HWND; X, Y, CX, CY: Integer);
  begin
    if C <> 0 then MoveWindow(C, X, Y, Max(0,CX), Max(0,CY), True);
  end;
begin
  if FChrome.Settings = 0 then Exit;
  GetClientRect(FWnd, R);
  L := LayoutViewerChrome(FWnd, FChrome, Min(ViewerPixels(FWnd, 240), R.Right div 3),
    ViewerPixels(FWnd, 22), True);
  NavTop := L.FilterBottom;
  NavHeight := L.RowHeight - L.Margin;
  TextTab := TabCtrl_GetCurSel(FTabs) = 1;
  GroupWidth := Max(0, L.LeftWidth - L.Margin);
  Place(FPrevGroup, L.Margin, L.RowHeight + L.Margin, GroupWidth div 2, NavHeight);
  Place(FNextGroup, L.Margin + GroupWidth div 2, L.RowHeight + L.Margin,
    GroupWidth - GroupWidth div 2, NavHeight);
  Place(FTree, L.Margin, NavTop, GroupWidth, L.StatusTop - NavTop);
  Place(FTabs, L.RightX, L.Margin, L.TabWidth, L.RowHeight);
  NavWidth := Min(ViewerPixels(FWnd, 106), L.RightWidth div 4);
  Place(FPrev, L.RightX, NavTop, NavWidth, NavHeight);
  Place(FNext, L.RightX + NavWidth, NavTop, NavWidth, NavHeight);
  Place(FPrevColumn, L.RightX + 2 * NavWidth, NavTop, NavWidth, NavHeight);
  Place(FNextColumn, L.RightX + 3 * NavWidth, NavTop, NavWidth, NavHeight);
  if TextTab then
  begin
    ShowWindow(FPrev, SW_SHOW);
    ShowWindow(FNext, SW_SHOW);
  end
  else
  begin
    ShowWindow(FPrev, SW_HIDE);
    ShowWindow(FNext, SW_HIDE);
  end;
  BodyTop := NavTop + L.RowHeight;
  Place(FGrid, L.RightX, BodyTop, L.RightWidth, L.StatusTop - BodyTop);
  Place(FText, L.RightX, BodyTop, L.RightWidth, L.StatusTop - BodyTop);
  Place(FStatus, L.Margin, L.StatusTop, R.Right - 2 * L.Margin, R.Bottom - L.StatusTop);
end;

procedure TLargeViewer.ApplyFont;
var Font: HFONT;
    Size: Integer;
begin
  Size := ReadSettingInt('font-size', 16);
  if (Size < 10) or (Size > 48) then Size := 16;
  Font := CreateFontW(ViewerPixels(FWnd, Size), 0, 0, 0,
    FW_NORMAL + 300 * Ord(ReadSettingInt('font-use-bold', 0) <> 0), 0, 0, 0,
    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
    DEFAULT_PITCH, PWideChar(ReadSetting('font', 'Arial')));
  if Font = 0 then Exit;
  SendMessageW(FTree, WM_SETFONT, Font, 1);
  SendMessageW(FGrid, WM_SETFONT, Font, 1);
  SendMessageW(ListView_GetHeader(FGrid), WM_SETFONT, Font, 1);
  ApplyViewerFontToText(FText, Font);
  if FDataFont <> 0 then DeleteObject(FDataFont);
  FDataFont := Font;
end;

procedure TLargeViewer.OpenSettings;
begin
  if not ShowSettingsDialog(FWnd, FDark) then Exit;
  ApplyPendingFilter;
  ApplyFont;
  ApplyTheme;
  FQuery.CaseSensitive := ReadSettingInt('filter-case-sensitive', 0) <> 0;
  RequestView;
end;

procedure TLargeViewer.ApplyTheme;
var Style: PWideChar;
    Mode: TThemeMode;
begin
  Mode := ConfiguredThemeMode;
  FDark := (Mode = tmDark) or
    ((Mode = tmTotalCommander) and ((FShowFlags and lcp_darkmode) <> 0));
  Style := nil;
  FBackColor := GetSysColor(COLOR_WINDOW);
  FTextColor := GetSysColor(COLOR_WINDOWTEXT);
  FFilterBackColor := FBackColor;
  FFilterTextColor := FTextColor;
  FBorderColor := GetSysColor(COLOR_3DSHADOW);
  if FDark then
  begin
    Style := 'DarkMode_Explorer';
    FBackColor := ReadSettingInt('back-color-dark', RGB(32,32,32));
    FTextColor := ReadSettingInt('text-color-dark', RGB(220,220,220));
    FFilterBackColor := ReadSettingInt('filter-back-color-dark', RGB(60,60,60));
    FFilterTextColor := ReadSettingInt('filter-text-color-dark', RGB(255,255,255));
    FBorderColor := ReadSettingInt('splitter-color-dark', RGB(64,64,64));
    FJsonTextColor := ReadSettingInt('json-text-color-dark', RGB(220,220,220));
    FKeyColor := ReadSettingInt('json-key-color-dark', RGB(219,161,239));
    FStringColor := ReadSettingInt('json-string-color-dark', RGB(165,211,143));
    FBooleanColor := ReadSettingInt('json-boolean-color-dark', RGB(130,185,255));
    FNullColor := ReadSettingInt('json-null-color-dark', RGB(242,163,149));
  end
  else
  begin
    FJsonTextColor := ReadSettingInt('json-text-color', RGB(0,0,0));
    FKeyColor := ReadSettingInt('json-key-color', RGB(128,0,128));
    FStringColor := ReadSettingInt('json-string-color', RGB(0,128,0));
    FBooleanColor := ReadSettingInt('json-boolean-color', RGB(0,0,255));
    FNullColor := ReadSettingInt('json-null-color', RGB(255,0,0));
  end;
  FUseBold := ReadSettingInt('font-use-bold', 0) <> 0;
  if FBrush <> 0 then DeleteObject(FBrush);
  FBrush := CreateSolidBrush(FBackColor);
  if FFilterBrush <> 0 then DeleteObject(FFilterBrush);
  FFilterBrush := CreateSolidBrush(FFilterBackColor);
  SetWindowTheme(FGrid, Style, nil);
  SetWindowTheme(FTree, Style, nil);
  SetWindowTheme(FText, Style, nil);
  ThemeViewerChrome(FChrome, FDark);
  SetWindowTheme(ListView_GetHeader(FGrid), Style, nil);
  ListView_SetBkColor(FGrid, FBackColor);
  ListView_SetTextBkColor(FGrid, FBackColor);
  ListView_SetTextColor(FGrid, FTextColor);
  SendMessageW(FTree, TVM_SETBKCOLOR, 0, FBackColor);
  SendMessageW(FTree, TVM_SETTEXTCOLOR, 0, FTextColor);
  SendMessageW(FText, EM_SETBKGNDCOLOR, 0, FBackColor);
  ApplyTextPalette;
  MarkText;
  RedrawWindow(FWnd, nil, 0, RDW_INVALIDATE or RDW_ERASE or RDW_FRAME or RDW_ALLCHILDREN);
end;

procedure TLargeViewer.ApplyTextPalette;
var CF: TCharFormat2W;
begin
  CF := Default(TCharFormat2W);
  CF.cbSize := SizeOf(CF);
  CF.dwMask := CFM_COLOR;
  CF.crTextColor := FJsonTextColor;
  SendMessageW(FText, EM_SETCHARFORMAT, SCF_ALL, LPARAM(@CF));
  SendMessageW(FText, EM_SETCHARFORMAT, SCF_DEFAULT, LPARAM(@CF));
  FFirstColored := -1;
end;

function TLargeViewer.ControlMessage(Wnd: HWND; Msg: UINT; W: WPARAM; L: LPARAM;
  out AResult: LRESULT): Boolean;
var Paint: TPaintStruct;
    Combo, CustomChrome: Boolean;
begin
  Result := True;
  Combo := (Wnd = FChrome.GroupBy) or (Wnd = FChrome.Field);
  if ((Msg = WM_KEYDOWN) or (Msg = WM_CHAR)) and (W = VK_ESCAPE) then
  begin
    // Preserve the ordinary Escape behavior of an open drop-down.
    if Combo and (SendMessageW(Wnd, CB_GETDROPPEDSTATE, 0, 0) <> 0) then Exit(False);
    if Msg = WM_KEYDOWN then PostMessageW(GetParent(FWnd), Msg, W, L);
    AResult := 0;
    Exit;
  end;
  if FDark and (Wnd = FGrid) and (Msg = WM_NOTIFY) and
    DrawGridHeader(Wnd, PNMHDR(L), True, FFilterBackColor,
      FFilterTextColor, FBorderColor, FDataFont, AResult) then Exit;
  if FDark and (Wnd = FText) then
    case Msg of
      WM_PRINT:
        if L and PRF_NONCLIENT <> 0 then
        begin
          AResult := DefSubclassProc(Wnd, Msg, W, L);
          PaintTextScrollbars(Wnd, HDC(W), FBackColor, FFilterBackColor, FTextColor);
          Exit;
        end;
      WM_NCPAINT, WM_NCACTIVATE, WM_VSCROLL, WM_HSCROLL, WM_MOUSEWHEEL, WM_SETTEXT:
        begin
          AResult := DefSubclassProc(Wnd, Msg, W, L);
          PaintTextScrollbars(Wnd, 0, FBackColor, FFilterBackColor, FTextColor);
          Exit;
        end;
    end;
  CustomChrome := FDark and (Combo or (Wnd = FTabs) or
    (Wnd = FPrev) or (Wnd = FNext) or (Wnd = FPrevGroup) or
    (Wnd = FNextGroup) or (Wnd = FPrevColumn) or (Wnd = FNextColumn));
  if CustomChrome then
    case Msg of
      WM_ERASEBKGND: begin AResult := 1; Exit; end;
      WM_PAINT:
        begin
          BeginPaint(Wnd, Paint);
          try
            PaintChrome(Wnd, Paint.hdc);
          finally
            EndPaint(Wnd, Paint);
          end;
          AResult := 0;
          Exit;
        end;
      WM_PRINTCLIENT:
        begin
          PaintChrome(Wnd, HDC(W));
          AResult := 0;
          Exit;
        end;
    end;
  Result := False;
end;

procedure TLargeViewer.PaintChrome(Wnd: HWND; DC: HDC);
var R, TextRect: TRect;
    Tab: TTCItemW;
    Buffer: array[0..63] of WideChar;
    Caption: UnicodeString;
    Saved, I, X, Y, Selected: Integer;
    Fore, Back: COLORREF;
    Border: HBRUSH;
    Pen: HPEN;
    Combo: Boolean;
begin
  Saved := SaveDC(DC);
  Border := CreateSolidBrush(FBorderColor);
  try
    GetClientRect(Wnd, R);
    SelectObject(DC, FFont);
    SetBkMode(DC, TRANSPARENT);
    Fore := FFilterTextColor;
    if not IsWindowEnabled(Wnd) then Fore := RGB(160,160,160);
    SetTextColor(DC, Fore);
    if Wnd = FTabs then
    begin
      FillColor(DC, R, FBackColor);
      Selected := TabCtrl_GetCurSel(Wnd);
      for I := 0 to TabCtrl_GetItemCount(Wnd) - 1 do
      begin
        if SendMessageW(Wnd, TCM_GETITEMRECT, I, LPARAM(@R)) = 0 then Continue;
        Back := FBackColor;
        if I = Selected then Back := FFilterBackColor;
        FillColor(DC, R, Back);
        FrameRect(DC, R, Border);
        Tab := Default(TTCItemW);
        Buffer[0] := #0;
        Tab.mask := TCIF_TEXT;
        Tab.pszText := @Buffer[0];
        Tab.cchTextMax := Length(Buffer);
        SendMessageW(Wnd, TCM_GETITEMW, I, LPARAM(@Tab));
        DrawTextW(DC, @Buffer[0], -1, R, DT_CENTER or DT_SINGLELINE or DT_VCENTER or DT_NOPREFIX);
        if (I = Selected) and (GetFocus = Wnd) then
        begin
          InflateRect(R, -2, -2);
          DrawFocusRect(DC, R);
        end;
      end;
      Exit;
    end;
    Combo := (Wnd = FChrome.GroupBy) or (Wnd = FChrome.Field);
    Back := FFilterBackColor;
    if not IsWindowEnabled(Wnd) or
      ((not Combo) and (SendMessageW(Wnd, BM_GETSTATE, 0, 0) and BST_PUSHED <> 0)) then
      Back := FBackColor;
    FillColor(DC, R, Back);
    FrameRect(DC, R, Border);
    TextRect := R;
    if Combo then
    begin
      Caption := ComboItemText(Wnd, SendMessageW(Wnd, CB_GETCURSEL, 0, 0));
      Inc(TextRect.Left, 5);
      Dec(TextRect.Right, GetSystemMetrics(SM_CXVSCROLL));
      DrawTextW(DC, PWideChar(Caption), Length(Caption), TextRect,
        DT_LEFT or DT_SINGLELINE or DT_VCENTER or DT_END_ELLIPSIS or DT_NOPREFIX);
      X := (TextRect.Right + R.Right) div 2;
      Y := (R.Top + R.Bottom) div 2;
      Pen := CreatePen(PS_SOLID, 1, Fore);
      SelectObject(DC, Pen);
      MoveToEx(DC, X-3, Y-1, nil);
      LineTo(DC, X, Y+2);
      LineTo(DC, X+4, Y-2);
      SelectObject(DC, GetStockObject(BLACK_PEN));
      DeleteObject(Pen);
      R.Right := TextRect.Right;
    end
    else
    begin
      Caption := ChildText(Wnd);
      DrawTextW(DC, PWideChar(Caption), Length(Caption), TextRect,
        DT_CENTER or DT_SINGLELINE or DT_VCENTER or DT_NOPREFIX);
    end;
    if GetFocus = Wnd then
    begin
      InflateRect(R, -2, -2);
      DrawFocusRect(DC, R);
    end;
  finally
    RestoreDC(DC, Saved);
    DeleteObject(Border);
  end;
end;

procedure TLargeViewer.RequestView;
begin
  Inc(FQuery.Revision);
  Inc(FQuery.Ticket);
  Inc(FQuery.FindTicket);
  FQuery.FindText := '';
  FLastFind := -1;
  FQuery.PageStart := 0;
  FQuery.TextOffset := 0;
  if TabCtrl_GetCurSel(FTabs) = 1 then FQuery.TextRow := -1 else FQuery.TextRow := -2;
  FTextHistory := nil;
  FWasRequested := 0;
  FNeedPage := -1;
  FCache := nil;
  FGridBase := 0;
  FLastRows := 0;
  FInTree := True;
  try
    ClearRecordNodes;
  finally
    FInTree := False;
  end;
  ListView_SetItemCount(FGrid, 0);
  FFirstColored := -1;
  SetWindowTextW(FText, '');
  FWorker.Request(FQuery);
end;

procedure TLargeViewer.RequestPage(AtRow: Int64);
begin
  if (AtRow < 0) or (AtRow >= FState.Rows) then Exit;
  FQuery.PageStart := AtRow div LargePageRows * LargePageRows;
  FWasRequested := FQuery.PageStart;
  FNeedPage := -1;
  Inc(FQuery.Ticket);
  FWorker.Request(FQuery);
end;

procedure TLargeViewer.RequestText;
begin
  Inc(FQuery.Ticket);
  FWorker.Request(FQuery);
end;

procedure TLargeViewer.TextPage(Step: Integer);
var L: Integer;
begin
  if TabCtrl_GetCurSel(FTabs) <> 1 then
  begin
    SetGridPosition(Max(Int64(0), SelectedGridRow) + Step * LargePageRows, True);
    Exit;
  end;
  L := Length(FTextHistory);
  if Step < 0 then
  begin
    if L = 0 then Exit;
    if FQuery.TextRow >= 0 then FQuery.TextOffset := FTextHistory[L - 1]
    else FQuery.PageStart := FTextHistory[L - 1];
    SetLength(FTextHistory, L - 1);
  end
  else
  begin
    if FState.TextNext = 0 then Exit;
    SetLength(FTextHistory, L + 1);
    if FQuery.TextRow >= 0 then
    begin
      FTextHistory[L] := FQuery.TextOffset;
      FQuery.TextOffset := FState.TextNext;
    end
    else
    begin
      FTextHistory[L] := FQuery.PageStart;
      FQuery.PageStart := FState.TextNext;
    end;
  end;
  RequestText;
end;

function StreamingFieldCaption(const Name: UTF8String; Root: TJsonRoot): UnicodeString;
begin
  if Name = '' then Exit(Tr('(empty key)', '(пустой ключ)'));
  if (Root = jrObject) and (Name = 'Attribute') then Exit(Tr('Attribute', 'Атрибут'));
  if (Root in [jrObject, jrScalar]) and (Name = 'Value') then Exit(Tr('Value', 'Значение'));
  Result := UTF8Decode(Name);
end;

procedure TLargeViewer.UpdateColumns(const NewState: TLargeSnapshot);
var I, J, Match, OldCount, W: Integer;
    Different, Prefix, RebuildChoices: Boolean;
    Col: TLVColumnW;
    Field, Active: UnicodeString;
    Order: array of Integer;
begin
  Different := (Length(FState.Fields) <> Length(NewState.Fields)) or
    (FState.ColumnsAt <> NewState.ColumnsAt) or (FState.Generation <> NewState.Generation);
  Prefix := (FState.ColumnsAt = NewState.ColumnsAt) and
    (FState.Generation = NewState.Generation) and (Length(NewState.Fields) >= Length(FState.Fields));
  if Prefix then
    for I := 0 to High(FState.Fields) do
      if FState.Fields[I].Name <> NewState.Fields[I].Name then
      begin
        Prefix := False;
        Break;
      end;
  Different := Different or not Prefix;
  RebuildChoices := Different or (Length(FState.GroupFields) <> Length(NewState.GroupFields)) or
    (FGroupOption <> FQuery.GroupField) or (FHasGroupOption <> FQuery.Grouping);
  if not RebuildChoices then
    for I := 0 to High(FState.GroupFields) do
      if FState.GroupFields[I].Name <> NewState.GroupFields[I].Name then
      begin
        RebuildChoices := True;
        Break;
      end;
  if RebuildChoices then
  begin
    FInColumns := True;
    FGroupOption := FQuery.GroupField;
    FHasGroupOption := FQuery.Grouping;
    I := SendMessageW(FChrome.Field, CB_GETCURSEL, 0, 0);
    Active := '';
    if (I >= 0) and (I <= High(FState.Fields)) then Active := UTF8Decode(FState.Fields[I].Name);
    SendMessageW(FChrome.GroupBy, CB_RESETCONTENT, 0, 0);
    SendMessageW(FChrome.Field, CB_RESETCONTENT, 0, 0);
    ComboAdd(FChrome.GroupBy, Tr('Group by: file order', 'Группировка: порядок файла'));
    Match := 0;
    if FQuery.Grouping then
    begin
      ComboAdd(FChrome.GroupBy, Tr('Group by: ', 'Группировка: ') + UTF8Decode(FQuery.GroupField));
      Match := 1;
    end;
    for I := 0 to High(NewState.GroupFields) do
      if not FQuery.Grouping or (NewState.GroupFields[I].Name <> FQuery.GroupField) then
      begin
        J := ComboAdd(FChrome.GroupBy, UTF8Decode(NewState.GroupFields[I].Name));
        SendMessageW(FChrome.GroupBy, CB_SETITEMDATA, J, I + 1);
      end;
    SendMessageW(FChrome.GroupBy, CB_SETCURSEL, Match, 0);
    EnableWindow(FChrome.GroupBy, Length(NewState.GroupFields) > 0);
    Match := 0;
    for I := 0 to High(NewState.Fields) do
    begin
      Field := StreamingFieldCaption(NewState.Fields[I].Name, NewState.Root);
      ComboAdd(FChrome.Field, Field);
      if UTF8Decode(NewState.Fields[I].Name) = Active then Match := I;
    end;
    SendMessageW(FChrome.Field, CB_SETCURSEL, Match, 0);
    FInColumns := False;
    if (Match <= High(NewState.Fields)) and
      (Active <> UTF8Decode(NewState.Fields[Match].Name)) then
      SyncFilterEditor(NewState.Fields[Match].Name);
  end;
  if not Different then Exit;

  OldCount := Header_GetItemCount(ListView_GetHeader(FGrid));
  if not Prefix then
  begin
    for I := OldCount - 1 downto 0 do
    begin
      if I <= High(FState.Fields) then
        FWidths.Values[FState.Fields[I].Name] :=
          IntToStr(ListView_GetColumnWidth(FGrid, I));
      ListView_DeleteColumn(FGrid, I);
    end;
    OldCount := 0;
    FCache := nil;
  end
  else if OldCount > 0 then
  begin
    SetLength(Order, Length(NewState.Fields));
    SendMessageW(FGrid, LVM_GETCOLUMNORDERARRAY, OldCount, LPARAM(@Order[0]));
  end;

  for I := OldCount to High(NewState.Fields) do
  begin
    Field := StreamingFieldCaption(NewState.Fields[I].Name, NewState.Root);
    W := StrToIntDef(FWidths.Values[NewState.Fields[I].Name], 160);
    Col := Default(TLVColumnW);
    Col.mask := LVCF_TEXT or LVCF_WIDTH or LVCF_SUBITEM;
    Col.pszText := PWideChar(Field);
    Col.cx := W;
    Col.iSubItem := I;
    SendMessageW(FGrid, LVM_INSERTCOLUMNW, I, LPARAM(@Col));
    if Length(Order) > I then Order[I] := I;
  end;
  if Length(Order) > 0 then
    SendMessageW(FGrid, LVM_SETCOLUMNORDERARRAY, Length(Order), LPARAM(@Order[0]));
end;

procedure TLargeViewer.UpdateTree(const NewState: TLargeSnapshot);
var I: Integer;
    Item: TTVItemW;
    Caption: UnicodeString;
begin
  FInTree := True;
  try
    if FShownGroup <> FQuery.GroupStart then
    begin
      ClearRecordNodes;
      FShownGroup := FQuery.GroupStart;
    end;
    for I := High(FSlots) downto Length(NewState.GroupItems) do
      SendMessageW(FTree, TVM_DELETEITEM, 0, LPARAM(FSlots[I]));
    SetLength(FSlots, Length(NewState.GroupItems));
    SetLength(FSlotCaptions, Length(FSlots));
    for I := 0 to High(FSlots) do
    begin
      Caption := NewState.GroupItems[I].Caption + ' (' +
        IntToStr(NewState.GroupItems[I].Count) + ')';
      if FSlots[I] = nil then
        FSlots[I] := TreeAdd(FTree, FTitle, Caption, NewState.GroupItems[I].Id)
      else if Caption <> FSlotCaptions[I] then
      begin
        Item := Default(TTVItemW);
        Item.hItem := FSlots[I];
        Item.mask := TVIF_TEXT or TVIF_PARAM;
        Item.pszText := PWideChar(Caption);
        Item.lParam := NewState.GroupItems[I].Id;
        SendMessageW(FTree, TVM_SETITEMW, 0, LPARAM(@Item));
      end;
      FSlotCaptions[I] := Caption;
    end;
    if Length(FState.GroupItems) = 0 then
      SendMessageW(FTree, TVM_EXPAND, TVE_EXPAND, LPARAM(FTitle));
    UpdateRecordNodes(NewState.Rows);
    EnableWindow(FPrevGroup, FQuery.GroupStart > 0);
    EnableWindow(FNextGroup, NewState.Groups > FQuery.GroupStart + LargeGroupPage);
  finally
    FInTree := False;
  end;
end;

procedure TLargeViewer.ClearRecordNodes;
var Item: HTREEITEM;
begin
  for Item in FRecordNodes do SendMessageW(FTree, TVM_DELETEITEM, 0, LPARAM(Item));
  FRecordNodes := nil;
  FNodeStart := -1;
  FNodeParent := nil;
  FNodeCount := 0;
end;

procedure TLargeViewer.UpdateRecordNodes(Count: Int64);
var Parent: HTREEITEM;
    I, Slot, Amount: Integer;
    First: Int64;
begin
  Parent := FTitle;
  if FQuery.Grouping then
  begin
    Slot := FQuery.GroupId - FQuery.GroupStart - 1;
    if (Slot >= 0) and (Slot <= High(FSlots)) then Parent := FSlots[Slot]
    else Parent := nil;
  end;
  First := FQuery.PageStart;
  Amount := Min(Int64(64), Max(Int64(0), Count - First));
  if Parent = nil then Amount := 0;
  if (Parent = FNodeParent) and (FNodeStart = First) and (FNodeCount = Amount) then Exit;
  ClearRecordNodes;
  FNodeParent := Parent;
  FNodeStart := First;
  FNodeCount := Amount;
  SetLength(FRecordNodes, Amount);
  for I := 0 to Amount - 1 do
    FRecordNodes[I] := TreeAdd(FTree, Parent, Tr('Row ', 'Строка ') + IntToStr(First + I + 1), -(I + 1));
end;

procedure TLargeViewer.UpdateGridCount;
var N: Int64;
begin
  N := EnsureRange(FState.Rows - FGridBase, Int64(0), Int64(ViewRows));
  if N <> FLastRows then
  begin
    SendMessageW(FGrid, LVM_SETITEMCOUNT, N, LVSICF_NOINVALIDATEALL or LVSICF_NOSCROLL);
    FLastRows := N;
  end;
end;

procedure TLargeViewer.UpdateSnapshot;
var S: TLargeSnapshot;
    I: Integer;
begin
  S := FWorker.Snapshot;
  if S.Revision <> FQuery.Revision then Exit;
  if S.Generation <> FGeneration then
  begin
    FGeneration := S.Generation;
    FCache := nil;
    FWasRequested := -1;
    FTextTicket := -1;
  end;
  UpdateColumns(S);
  UpdateTree(S);
  FState := S;
  UpdateGridCount;
  if (S.Page.Bytes > 0) and (S.Ticket = FQuery.Ticket) and (S.Page.Revision = FQuery.Revision) then
    CachePage(S.Page);
  if (S.Ticket = FQuery.Ticket) and (S.Ticket <> FTextTicket) and
    (S.TextRow = FQuery.TextRow) and (FQuery.TextRow <> -2) and (S.Text <> '') then
  begin
    FTextTicket := S.Ticket;
    SetWindowTextW(FText, PWideChar(S.Text));
    ApplyViewerFontToText(FText, FDataFont);
    ApplyTextPalette;
  end;
  if ((S.Status and StatusSearchDone) <> 0) and (S.FindTicket = FQuery.FindTicket) and
    (FFindTicket <> S.FindTicket) then
  begin
    FFindTicket := S.FindTicket;
    FLastFind := S.FoundRow;
    if S.FoundRow >= 0 then SetGridPosition(S.FoundRow, True);
  end;
  EnableWindow(FPrevColumn, FQuery.ColumnStart > 0);
  EnableWindow(FNextColumn, FState.FieldCount > FQuery.ColumnStart + LargeColumnPage);
  if FNeedPage >= 0 then
  begin
    I := ListView_GetTopIndex(FGrid);
    if (FNeedPage >= I + FGridBase - LargePageRows) and
      (FNeedPage <= I + FGridBase + 2 * LargePageRows) then RequestPage(FNeedPage)
    else FNeedPage := -1;
  end;
  MarkText;
  UpdateStatus;
end;

procedure TLargeViewer.UpdateStatus;
var Status, Filters: UnicodeString;
    I: Integer;
begin
  Status := Tr('Records: ', 'Записи: ') + IntToStr(FState.Rows) + ' / ' + IntToStr(FState.TotalRows);
  if (FState.Status and StatusError) <> 0 then Status := Status + Tr(' | Partial: ', ' | Частично: ') + FState.Error
  else if (FState.Status and StatusIndexDone) = 0 then
  begin
    Status := Status + Tr(' | Indexing', ' | Индексация');
    if FState.Size > 0 then Status := Status + ' ' +
      IntToStr(Trunc((FState.Processed / FState.Size) * 100)) + '%';
  end
  else Status := Status + Tr(' | Indexed', ' | Индекс готов');
  if FQuery.Grouping then
  begin
    Status := Status + Tr(' | Groups: ', ' | Группы: ') + IntToStr(FState.Groups);
    if (FState.Status and StatusGroupDone) = 0 then Status := Status + Tr(' (building)', ' (построение)');
  end;
  if Length(FQuery.Filters) <> 0 then
  begin
    if (FState.Status and StatusFilterDone) = 0 then Status := Status + Tr(' | Filtering', ' | Фильтрация')
    else Status := Status + Tr(' | Filtered', ' | Отфильтровано');
  end;
  if FQuery.FindText <> '' then
  begin
    Status := Status + Tr(' | Search in current view', ' | Поиск в текущем представлении');
    if FState.FindTicket <> FQuery.FindTicket then Status := Status + '...'
    else if FState.FoundRow < 0 then Status := Status + Tr(': no match', ': нет совпадений')
    else Status := Status + Tr(': row ', ': строка ') + IntToStr(FState.FoundRow + 1);
  end;
  if TabCtrl_GetCurSel(FTabs) = 1 then
  begin
    if FQuery.TextRow >= 0 then Status := Status + Tr(' | Row ', ' | Строка ') + IntToStr(FQuery.TextRow + 1)
    else Status := Status + Tr(' | Text from row ', ' | Текст со строки ') + IntToStr(FQuery.PageStart + 1);
  end;
  if ChildText(FStatus) <> Status then SetWindowTextW(FStatus, PWideChar(Status));
  Filters := Tr('Read-only, file order', 'Только чтение, порядок файла');
  for I := 0 to High(FQuery.Filters) do
    Filters := Filters + ' | ' + StreamingFieldCaption(FQuery.Filters[I].Field, FState.Root) + ': ' + FQuery.Filters[I].Pattern;
  if ChildText(FChrome.FilterSummary) <> Filters then SetWindowTextW(FChrome.FilterSummary, PWideChar(Filters));
end;

procedure TLargeViewer.CachePage(const Page: TLargePage);
var I, J, Total: Integer;
    Same: Boolean;
begin
  if Page.ColumnStart <> FQuery.ColumnStart then Exit;
  for I := 0 to High(FCache) do
    if FCache[I].First = Page.First then
    begin
      Same := Length(FCache[I].Rows) = Length(Page.Rows);
      if Same and (Length(Page.Rows) > 0) then
        Same := @FCache[I].Rows[0] = @Page.Rows[0];
      if Same then Exit;
      for J := I to High(FCache) - 1 do FCache[J] := FCache[J + 1];
      SetLength(FCache, Length(FCache) - 1);
      Break;
    end;
  Total := Page.Bytes;
  for I := 0 to High(FCache) do Inc(Total, FCache[I].Bytes);
  I := 0;
  while (Total > GridBudget) and (I < Length(FCache)) do
  begin
    Dec(Total, FCache[I].Bytes);
    Inc(I);
  end;
  if I > 0 then
  begin
    for J := I to High(FCache) do FCache[J - I] := FCache[J];
    SetLength(FCache, Length(FCache) - I);
  end;
  SetLength(FCache, Length(FCache) + 1);
  FCache[High(FCache)] := Page;
  if (Page.First >= FGridBase) and (Page.First - FGridBase < ViewRows) then
    ListView_RedrawItems(FGrid, Page.First - FGridBase,
      Min(Int64(ViewRows - 1), Page.First - FGridBase + High(Page.Rows)));
end;

function TLargeViewer.ReadCell(Row: Int64; Col: Integer): UnicodeString;
var I, J, Relative: Integer;
    Page: TLargePage;
begin
  for I := High(FCache) downto 0 do
    if (Row >= FCache[I].First) and (Row - FCache[I].First < Length(FCache[I].Rows)) then
    begin
      Page := FCache[I];
      Relative := Row - Page.First;
      if (Col >= 0) and (Col <= High(Page.Rows[Relative])) then
      begin
        for J := I to High(FCache) - 1 do FCache[J] := FCache[J + 1];
        FCache[High(FCache)] := Page;
        Exit(Page.Rows[Relative][Col]);
      end;
    end;
  if (Row div LargePageRows * LargePageRows <> FWasRequested) or
    ((FState.Ticket = FQuery.Ticket) and (FState.Page.First = FWasRequested)) then
    if (FNeedPage < 0) or (Row div LargePageRows = (FGridBase + ListView_GetTopIndex(FGrid)) div LargePageRows) then
      FNeedPage := Row;
  Result := Ellipsis;
end;

function TLargeViewer.SelectedGridRow: Int64;
var Id: Integer;
begin
  Id := ListView_GetNextItem(FGrid, -1, LVNI_SELECTED);
  if Id < 0 then Result := -1 else Result := Id + FGridBase;
end;

procedure TLargeViewer.SetGridPosition(Row: Int64; Select: Boolean);
var Slot: Integer;
begin
  if FState.Rows = 0 then Exit;
  Row := EnsureRange(Row, Int64(0), FState.Rows - 1);
  if (Row < FGridBase) or (Row >= FGridBase + ViewRows) then
  begin
    FGridBase := Row div ViewRows * ViewRows;
    FLastRows := 0;
    UpdateGridCount;
  end;
  Slot := Row - FGridBase;
  ListView_EnsureVisible(FGrid, Slot, False);
  if Select then
    ListView_SetItemState(FGrid, Slot, LVIS_FOCUSED or LVIS_SELECTED, LVIS_FOCUSED or LVIS_SELECTED);
  if TabCtrl_GetCurSel(FTabs) = 1 then
  begin
    FQuery.TextRow := Row;
    FQuery.TextOffset := 0;
    FTextHistory := nil;
  end;
  RequestPage(Row);
end;

procedure TLargeViewer.SetGroupField;
var N, I: Integer;
begin
  if FInColumns then Exit;
  N := SendMessageW(FChrome.GroupBy, CB_GETCURSEL, 0, 0);
  if N < 0 then Exit;
  if N = 0 then
  begin
    FQuery.Grouping := False;
    FQuery.GroupField := '';
  end
  else
  begin
    I := SendMessageW(FChrome.GroupBy, CB_GETITEMDATA, N, 0) - 1;
    if (I < 0) or (I > High(FState.GroupFields)) then Exit;
    FQuery.Grouping := True;
    FQuery.GroupField := FState.GroupFields[I].Name;
  end;
  FQuery.GroupId := 0;
  FQuery.GroupStart := 0;
  SendMessageW(FTree, TVM_SELECTITEM, TVGN_CARET, LPARAM(FTitle));
  RequestView;
end;

procedure TLargeViewer.SetGroup(Id: Int64);
begin
  if Id = FQuery.GroupId then Exit;
  FQuery.GroupId := Id;
  RequestView;
end;

procedure TLargeViewer.TreeSelected;
var Item: TTVItemW;
begin
  if FInTree then Exit;
  Item := Default(TTVItemW);
  Item.hItem := HTREEITEM(SendMessageW(FTree, TVM_GETNEXTITEM, TVGN_CARET, 0));
  Item.mask := TVIF_PARAM;
  if (Item.hItem <> nil) and (SendMessageW(FTree, TVM_GETITEMW, 0, LPARAM(@Item)) <> 0) then
  begin
    if Item.lParam < 0 then SetGridPosition(FNodeStart - Int64(Item.lParam) - 1, True)
    else SetGroup(Item.lParam);
  end;
end;

function TLargeViewer.SelectedFilterField(out Name: UTF8String): Boolean;
var Index: LRESULT;
begin
  Index := SendMessageW(FChrome.Field, CB_GETCURSEL, 0, 0);
  Result := (Index >= 0) and (Index <= High(FState.Fields));
  if Result then Name := FState.Fields[Index].Name;
end;

procedure TLargeViewer.SyncFilterEditor(const Name: UTF8String);
var Filter: TLargeFilter;
    Value: UnicodeString;
begin
  Value := '';
  for Filter in FQuery.Filters do
    if Filter.Field = Name then
    begin
      Value := Filter.Pattern;
      Break;
    end;
  if FFilterPending and (FPendingField = Name) then Value := FPendingValue;
  FUpdatingPattern := True;
  try
    SetWindowTextW(FChrome.Pattern, PWideChar(Value));
  finally
    FUpdatingPattern := False;
  end;
end;

procedure TLargeViewer.QueueFilter;
var Name: UTF8String;
begin
  if FClosing or FUpdatingPattern or (FWorker = nil) or
    not SelectedFilterField(Name) then Exit;
  if FFilterPending and (FPendingField <> Name) then ApplyPendingFilter;
  FPendingField := Name;
  FPendingValue := ChildText(FChrome.Pattern);
  FFilterPending := True;
  if SetTimer(FWnd, FilterTimer, ViewerFilterDelay, nil) = 0 then ApplyPendingFilter;
end;

procedure TLargeViewer.ApplyPendingFilter;
var I, J: Integer;
    Present: Boolean;
begin
  if FClosing or not FFilterPending then Exit;
  KillTimer(FWnd, FilterTimer);
  FFilterPending := False;
  I := 0;
  while (I < Length(FQuery.Filters)) and (FQuery.Filters[I].Field <> FPendingField) do Inc(I);
  Present := I < Length(FQuery.Filters);
  if (Present and (FQuery.Filters[I].Pattern = FPendingValue)) or
    (not Present and (FPendingValue = '')) then Exit;
  FQuery.Filters := Copy(FQuery.Filters);
  if FPendingValue = '' then
  begin
    for J := I to High(FQuery.Filters) - 1 do FQuery.Filters[J] := FQuery.Filters[J + 1];
    SetLength(FQuery.Filters, Length(FQuery.Filters) - 1);
  end
  else
  begin
    if not Present then SetLength(FQuery.Filters, I + 1);
    FQuery.Filters[I].Field := FPendingField;
    FQuery.Filters[I].Pattern := FPendingValue;
  end;
  FQuery.CaseSensitive := ReadSettingInt('filter-case-sensitive', 0) <> 0;
  RequestView;
end;

procedure TLargeViewer.ClearFilters;
var HadFilters: Boolean;
    Name: UTF8String;
begin
  FFilterPending := False;
  KillTimer(FWnd, FilterTimer);
  HadFilters := Length(FQuery.Filters) > 0;
  FQuery.Filters := nil;
  if SelectedFilterField(Name) then SyncFilterEditor(Name);
  if HadFilters then RequestView;
end;

procedure TLargeViewer.ChangeTab;
var IsText: Boolean;
    Row: Int64;
begin
  IsText := TabCtrl_GetCurSel(FTabs) = 1;
  Row := SelectedGridRow;
  FTextHistory := nil;
  FQuery.TextOffset := 0;
  if IsText then
  begin
    ShowWindow(FGrid, SW_HIDE);
    ShowWindow(FText, SW_SHOW);
    FQuery.TextRow := Row;
    if Row < 0 then FQuery.PageStart := FGridBase + ListView_GetTopIndex(FGrid);
  end
  else
  begin
    FQuery.TextRow := -2;
    ShowWindow(FText, SW_HIDE);
    ShowWindow(FGrid, SW_SHOW);
    FWasRequested := -1;
  end;
  Layout;
  RequestText;
end;

procedure TLargeViewer.MarkText;
begin
  if TabCtrl_GetCurSel(FTabs) <> 1 then Exit;
  HighlightVisibleJson(FText, FTextDocument, FKeyColor, FStringColor,
    FBooleanColor, FNullColor, FUseBold, FHighlighting, FFirstColored, FLastColored);
end;

procedure TLargeViewer.CopyView;
var I: Integer;
    Row: Int64;
    Text: UnicodeString;
    Data: HGLOBAL;
    Buf: Pointer;
begin
  if TabCtrl_GetCurSel(FTabs) = 1 then
  begin
    SendMessageW(FText, WM_COPY, 0, 0);
    Exit;
  end;
  Row := SelectedGridRow;
  if Row < 0 then Exit;
  for I := 0 to High(FState.Fields) do
  begin
    if I > 0 then Text := Text + #9;
    Text := Text + ReadCell(Row, I);
  end;
  if not OpenClipboard(FWnd) then Exit;
  try
    Data := GlobalAlloc(GMEM_MOVEABLE, (Length(Text) + 1) * SizeOf(WideChar));
    if Data = 0 then Exit;
    Buf := GlobalLock(Data);
    if Buf = nil then
    begin
      GlobalFree(Data);
      Exit;
    end;
    Move(PWideChar(Text)^, Buf^, (Length(Text) + 1) * SizeOf(WideChar));
    GlobalUnlock(Data);
    EmptyClipboard;
    if SetClipboardData(CF_UNICODETEXT, Data) = 0 then GlobalFree(Data);
  finally
    CloseClipboard;
  end;
end;

procedure TLargeViewer.ContextMenu(Source: HWND; X, Y: Integer);
var Menu: HMENU;
    Point: TPoint;
    Choice: UINT;
begin
  if (Source <> FGrid) and (Source <> FText) then Exit;
  Menu := CreatePopupMenu;
  try
    AppendMenuW(Menu, MF_STRING, 1, PWideChar(Tr('Copy', 'Копировать')));
    if Source = FGrid then AppendMenuW(Menu, MF_STRING, 2, PWideChar(Tr('Show selected record in Text', 'Показать запись в тексте')));
    if (X < 0) or (Y < 0) then
    begin
      GetCursorPos(Point);
      X := Point.X;
      Y := Point.Y;
    end;
    Choice := UINT(TrackPopupMenu(Menu, TPM_RETURNCMD or TPM_RIGHTBUTTON, X, Y, 0, FWnd, nil));
    if Choice = 1 then CopyView
    else if Choice = 2 then
    begin
      TabCtrl_SetCurSel(FTabs, 1);
      ChangeTab;
    end;
  finally
    DestroyMenu(Menu);
  end;
end;

function TLargeViewer.DoSearch(const Text: UnicodeString; Flags: Integer): Integer;
begin
  if Text = '' then Exit(0);
  if ((Flags and lcs_findfirst) <> 0) or (Text <> FQuery.FindText) then FLastFind := -1;
  FQuery.FindText := Text;
  FQuery.FindFlags := Flags;
  if (Flags and lcs_backwards) <> 0 then
  begin
    FQuery.FindFrom := FState.Rows - 1;
    if FLastFind >= 0 then FQuery.FindFrom := FLastFind - 1;
  end
  else FQuery.FindFrom := FLastFind + 1;
  Inc(FQuery.FindTicket);
  FWorker.Request(FQuery);
  Result := 0;
end;

function TLargeViewer.Dispatch(Msg: UINT; W: WPARAM; L: LPARAM): LRESULT;
var Hdr: PNMHdr;
    Info: PLargeListInfo;
    Hint: PLargeCacheHint;
    Text: UnicodeString;
    Name: UTF8String;
    DrawItem: PDrawItemStruct;
    R: TRect;
begin
  case Msg of
    WM_SIZE: Layout;
    $02E3: begin ApplyFont; Layout; end;
    WM_TIMER:
      if (W = RefreshTimer) and (FWorker <> nil) then UpdateSnapshot
      else if W = FilterTimer then ApplyPendingFilter;
    WM_MEASUREITEM:
      if (W = ViewerGroupID) or (W = ViewerFieldID) then
      begin
        PMeasureItemStruct(L)^.itemHeight := Abs(GetFontHeight(FFont)) + 5;
        Exit(1);
      end;
    WM_DRAWITEM:
      if (W = ViewerClearID) or (W = ViewerRefreshID) or (W = ViewerSettingsID) then
      begin
        DrawViewerButton(PDrawItemStruct(L)^, FDark, FFilterBackColor, FFilterTextColor, FBorderColor);
        Exit(1);
      end
      else if (W = ViewerGroupID) or (W = ViewerFieldID) then
      begin
        DrawItem := PDrawItemStruct(L);
        DrawComboItem(DrawItem^, FFont, FDark, FFilterBackColor, FFilterTextColor);
        Exit(1);
      end;
    WM_ERASEBKGND:
      if FBrush <> 0 then
      begin
        GetClientRect(FWnd, R);
        FillRect(HDC(W), R, FBrush);
        Exit(1);
      end;
    WM_CTLCOLORSTATIC, WM_CTLCOLOREDIT, WM_CTLCOLORLISTBOX:
      if FDark and (FBrush <> 0) then
      begin
        if (HWND(L) = FChrome.Pattern) or (Msg = WM_CTLCOLORLISTBOX) then
        begin
          SetBkColor(HDC(W), FFilterBackColor);
          SetTextColor(HDC(W), FFilterTextColor);
          Exit(FFilterBrush);
        end;
        SetBkColor(HDC(W), FBackColor);
        SetTextColor(HDC(W), FTextColor);
        Exit(FBrush);
      end;
    WM_KEYDOWN:
      if W = VK_ESCAPE then
      begin
        PostMessageW(GetParent(FWnd), Msg, W, L);
        Exit(0);
      end;
    WM_SETFOCUS: if IsWindowVisible(FText) then SetFocus(FText) else SetFocus(FGrid);
    WM_CONTEXTMENU: ContextMenu(HWND(W), SmallInt(LOWORD(L)), SmallInt(HIWORD(L)));
    WM_COMMAND:
      case LOWORD(W) of
        ViewerGroupID: if HIWORD(W) = CBN_SELCHANGE then SetGroupField;
        ViewerFieldID: if HIWORD(W) = CBN_SELCHANGE then
          begin
            ApplyPendingFilter;
            if SelectedFilterField(Name) then SyncFilterEditor(Name);
          end;
        ViewerPatternID: if HIWORD(W) = EN_CHANGE then QueueFilter;
        ViewerClearID: ClearFilters;
        PrevID: TextPage(-1);
        NextID: TextPage(1);
        ViewerRefreshID: begin ApplyPendingFilter; Inc(FQuery.Reload); RequestView; end;
        ViewerSettingsID: OpenSettings;
        PrevGroupID, NextGroupID:
          begin
            if LOWORD(W) = PrevGroupID then FQuery.GroupStart := Max(Int64(0), FQuery.GroupStart - LargeGroupPage)
            else Inc(FQuery.GroupStart, LargeGroupPage);
            RequestText;
          end;
        PrevColumnID, NextColumnID:
          begin
            if LOWORD(W) = PrevColumnID then FQuery.ColumnStart := Max(0, FQuery.ColumnStart - LargeColumnPage)
            else Inc(FQuery.ColumnStart, LargeColumnPage);
            FCache := nil;
            FWasRequested := -1;
            RequestText;
          end;
      end;
    WM_NOTIFY:
      if L <> 0 then
      begin
        Hdr := PNMHdr(L);
        if (Hdr^.idFrom = GridID) and (Integer(Hdr^.code) = LVN_GETDISPINFOW) then
        begin
          Info := PLargeListInfo(L);
          if ((Info^.Item.mask and LVIF_TEXT) <> 0) and (Info^.Item.cchTextMax > 0) then
          begin
            Text := ReadCell(FGridBase + Info^.Item.iItem, Info^.Item.iSubItem);
            lstrcpynW(Info^.Item.pszText, PWideChar(Text), Info^.Item.cchTextMax);
          end;
          Exit(0);
        end;
        if (Hdr^.idFrom = GridID) and (Integer(Hdr^.code) = LVN_ODCACHEHINT) then
        begin
          Hint := PLargeCacheHint(L);
          if Hint^.First >= 0 then ReadCell(Hint^.First + FGridBase, 0);
        end;
        if (Hdr^.idFrom = GridID) and (Integer(Hdr^.code) = NM_DBLCLK) then
        begin
          TabCtrl_SetCurSel(FTabs, 1);
          ChangeTab;
        end;
        if (Hdr^.idFrom = TreeID) and (Integer(Hdr^.code) = TVN_SELCHANGEDW) then TreeSelected;
        if (Hdr^.idFrom = TabsID) and (Integer(Hdr^.code) = TCN_SELCHANGE) then ChangeTab;
      end;
  end;
  Result := DefWindowProcW(FWnd, Msg, W, L);
end;

function CreateLargeViewer(Parent: HWND; const FileName: UnicodeString;
  Size: Int64; ShowFlags: Integer): HWND;
var V: TLargeViewer;
begin
  Result := 0;
  if not AllowedToOpen(Parent, Size) then Exit;
  try
    V := TLargeViewer.Create(Parent, FileName, ShowFlags);
    Result := V.FWnd;
  except
    on E: Exception do MessageBoxW(Parent, PWideChar(ViewerErrorText(E)), 'JSON Tab',
      MB_OK or MB_ICONERROR);
  end;
end;

procedure CloseLargeViewer(Wnd: HWND);
begin
  TLargeViewer(GetWindowLongPtrW(Wnd, GWLP_USERDATA)).Free;
end;

procedure SetLargeShowFlags(Wnd: HWND; Flags: Integer);
var V: TLargeViewer;
begin
  V := TLargeViewer(GetWindowLongPtrW(Wnd, GWLP_USERDATA));
  if V = nil then Exit;
  V.FShowFlags := Flags;
  V.ApplyTheme;
end;

function SearchLargeViewer(Wnd: HWND; const Text: UnicodeString; Flags: Integer): Integer;
var V: TLargeViewer;
begin
  V := TLargeViewer(GetWindowLongPtrW(Wnd, GWLP_USERDATA));
  if V = nil then Result := 0 else Result := V.DoSearch(Text, Flags);
end;

end.
