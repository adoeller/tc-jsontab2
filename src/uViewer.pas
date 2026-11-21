unit uViewer;

{$mode delphi}{$H+}{$codepage utf8}

interface

uses Windows;

function CreateJsonViewer(ParentWin: HWND; const FileName: UnicodeString;
  ShowFlags: Integer; MaxSize: Int64): HWND;
procedure CloseJsonViewer(Wnd: HWND);
procedure SetJsonViewerShowFlags(Wnd: HWND; ShowFlags: Integer);
function SearchJsonViewer(Wnd: HWND; const SearchText: UnicodeString;
  SearchFlags: Integer): Integer;

implementation

uses
  Messages, CommCtrl, RichEdit, ShellApi, SysUtils, Classes, Math, fpjson,
  uJsonModel, uJsonGrouping, uSettings, uViewerControls, uDecimalAlign, uRichEditRanges, listplug, uSettingsDialog, uLocale;

const
  CLASS_NAME = 'JsonTabFpcViewer';
  IDC_TREE = 101;
  IDC_TAB = 102;
  IDC_GRID = 103;
  IDC_TEXT = 104;
  IDC_STATUS = 105;
  IDC_CELL_EDITOR = 106;
  FilterTimer = 11;
  SPLITTER_WIDTH = 8;
  WMU_TREE_CHANGED = WM_USER + 1;
  WMU_TEXT_HIGHLIGHT = WM_APP + 1;
  IDM_COPY = 5000;
  IDM_COPY_ROWS = 5001;
  IDM_COPY_COLUMN = 5002;
  IDM_COPY_AS_JSON = 5003;
  IDM_COPY_JSONPATH = 5004;
  IDM_FILTERS = 5006;
  IDM_HIDE_COLUMN = 5007;
  IDM_SHOW_COLUMNS = 5008;
  IDM_EDIT_MODE = 5009;
  IDM_THEME_TC = 5010;
  IDM_THEME_LIGHT = 5011;
  IDM_THEME_DARK = 5012;
  THEME_NAMES: array[0..2] of UnicodeString = ('tc', 'light', 'dark');
  CSTR_EQUAL = 2;

type
  TUnicodeRow = array of UnicodeString;
  TUnicodeRows = array of TUnicodeRow;
  TJsonDataArray = array of TJSONData;
  TIntegerArray = array of Integer;
  TNMLVDispInfoW = record
    hdr: NMHDR;
    item: LVITEMW;
  end;
  PNMLVDispInfoW = ^TNMLVDispInfoW;

function CompareStringEx(lpLocaleName: PWideChar; dwCmpFlags: DWORD;
  lpString1: PWideChar; cchCount1: Integer; lpString2: PWideChar;
  cchCount2: Integer; lpVersionInformation, lpReserved: Pointer;
  lParam: LPARAM): Integer; stdcall; external 'kernel32.dll' name 'CompareStringEx';

function SetControlTheme(Wnd: HWND; SubApp, SubIdList: PWideChar): HRESULT; stdcall;
  external 'uxtheme.dll' name 'SetWindowTheme';

type
  TJsonViewer = class
  private
    FWnd, FTree, FTab, FGrid, FText, FStatus, FCellEditor: HWND;
    FTabOldProc, FGridOldProc, FTreeOldProc, FTextOldProc,
      FEditorOldProc, FStatusOldProc: WNDPROC;
    FRoot: TJSONData;
    FGroupedRoot: TJSONObject;
    FGroupField: TJSONStringType;
    FFileName: UnicodeString;
    FEncoding: UnicodeString;
    FDirty: Boolean;
    FMalformed: Boolean;
    FSplitter, FLayoutSplitter: Integer;
    FSplitterDragOffset: Integer;
    FDragging: Boolean;
    FDark: Boolean;
    FThemeMode: TThemeMode;
    FShowFlags: Integer;
    FFont, FHeaderFont, FTabFont: HFONT;
    FFontSize: Integer;
    FSavedSplitter: Integer;
    FSavedFilterVisible: Boolean;
    FSavedFontSize: Integer;
    FSavedTabNo: Integer;
    FCurrent: TJSONData;
    FScalarArray: Boolean;
    FSortColumn: Integer;
    FSortDescending: Boolean;
    FAllRows: TUnicodeRows;
    FAllRowData: TJsonDataArray;
    FVisibleRowData: TJsonDataArray;
    FVisibleRows: TIntegerArray;
    FChrome: TViewerChrome;
    FFilterFields, FGroupFields: TStringList;
    FPatterns: array of UnicodeString;
    FColumnFilters: array of UTF8String;
    FUpdatingPattern: Boolean;
    FMaxSize: Int64;
    FDecimalAnchorWidths: array of Integer;  // per-column anchor pixel width; 0 = not a decimal column
    FFilterVisible: Boolean;
    FEditMode: Boolean;
    FClosingEditor: Boolean;
    FTextDocument: ITextDocument;
    FHighlighting, FHighlightPending, FTextNeedsUpdate: Boolean;
    FColoredFirstLine, FColoredLastLine: Integer;
    FEditorRow, FEditorColumn: Integer;
    FCurrentRow: Integer;
    FCurrentColumn: Integer;
    FSearchText: UnicodeString;
    FSearchFlags, FSearchTab, FSearchRow, FSearchColumn, FSearchCellPos: Integer;
    FTextColor, FBackColor, FBackColor2, FFilterTextColor,
      FFilterBackColor, FCurrentCellColor, FSelectionTextColor,
      FSelectionBackColor, FSplitterColor, FJsonTextColor, FJsonKeyColor,
      FJsonStringColor, FJsonBooleanColor, FJsonNullColor: COLORREF;
    FFilterBrush: HBRUSH;
    procedure AddTreeNode(Parent: HTREEITEM; Data: TJSONData; const Caption: UnicodeString);
    procedure ExpandTreeNode(Item: HTREEITEM);
    procedure BuildTree;
    procedure ShowTreeMenu(const Position: TPoint);
    procedure SetTreeGrouping(Enabled: Boolean; const Field: TJSONStringType);
    function SelectedData: TJSONData;
    procedure UpdateSelection;
    procedure BuildGrid(Data: TJSONData);
    procedure UpdateText(Data: TJSONData);
    procedure UpdateStatus(Data: TJSONData; Rows: Integer);
    procedure Layout;
    procedure ApplyTheme;
    procedure SetThemeMode(Mode: TThemeMode);
    procedure UpdateShowFlags(ShowFlags: Integer);
    procedure ApplyTextPalette;
    procedure PaintTabs(DC: HDC);
    procedure PaintStatus(DC: HDC);
    procedure CopySelectedCell;
    procedure CopyRows;
    procedure CopyColumn;
    procedure CopyAsJson;
    procedure CopyJsonPath;
    procedure SortGrid(Column: Integer);
    procedure BuildFilterChoices;
    procedure BuildGroupChoices;
    procedure SyncFilterEditor;
    procedure ReadFilterEditor;
    procedure ClearFilters;
    procedure RefreshFile;
    procedure OpenSettings;
    procedure ApplyFont(NewSize: Integer);
    procedure ApplyFilters;
    procedure UpdateVirtualGrid;
    procedure AutoSizeVisibleColumns;
    procedure HideColumn(Column: Integer);
    procedure ShowAllColumns;
    procedure SetFontSize(NewSize: Integer);
    procedure ScheduleTextHighlight;
    procedure HighlightVisibleText;
    procedure OpenCurrentUrl;
    procedure SelectTreeData(Data: TJSONData);
    procedure NavigateGridRowToTree(Row: Integer);
    procedure SyncGridToText;
    procedure SyncTextToGrid;
    procedure SetCurrentCell(Row, Column: Integer);
    function HandleHotKey(Key: WPARAM): Boolean;
    function CellData(Row, Column: Integer): TJSONData;
    procedure ToggleEditMode;
    procedure BeginCellEdit(Row, Column: Integer);
    procedure CloseCellEdit(Accept: Boolean);
    function ApplyCellEdit(Row, Column: Integer;
      const Value: UnicodeString): Boolean;
    procedure UpdateEditStatus(const MessageText: UnicodeString = '');
    function ForwardHostHotKey(Key: WPARAM): Boolean;
    function SaveChanges: Boolean;
    procedure ConfirmSaveBeforeClose;
  public
    constructor Create(ParentWin: HWND; const FileName: UnicodeString; ShowFlags: Integer; MaxSize: Int64);
    destructor Destroy; override;
    function Search(const S: UnicodeString; Flags: Integer): Integer;
    property Handle: HWND read FWnd;
  end;

var
  ClassRegistered: Boolean;

function ChooseInt(Condition: Boolean; A, B: Integer): Integer;
begin
  if Condition then Result := A else Result := B;
end;

function DarkenColor(Color: COLORREF): COLORREF;
begin
  Result := RGB(GetRValue(Color) * 85 div 100,
    GetGValue(Color) * 85 div 100, GetBValue(Color) * 85 div 100);
end;

function ConfiguredFontWeight: Integer;
var
  Weight: Integer;
begin
  Weight := ReadSettingInt('font-weight', 0);
  if (Weight < 0) or (Weight > 9) then Result := FW_DONTCARE
  else Result := Weight * 100;
end;

function NaturalCompare(const A, B: UnicodeString): Integer;
const
  SORT_DIGITSASNUMBERS = $00000008;
var
  R: Integer;
  DA, DB: Double;
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  if TryStrToFloat(A, DA, FS) and TryStrToFloat(B, DB, FS) then
  begin
    if DA < DB then Exit(-1);
    if DA > DB then Exit(1);
    Exit(0);
  end;
  R := CompareStringEx(nil, NORM_IGNORECASE or
    NORM_IGNOREWIDTH or SORT_DIGITSASNUMBERS, PWideChar(A), Length(A),
    PWideChar(B), Length(B), nil, nil, 0);
  if R = 0 then
  begin
    if A < B then Result := -1
    else if A > B then Result := 1
    else Result := 0;
  end
  else
    Result := R - CSTR_EQUAL;
end;

// FPC's TTVItemW is TVITEMEX (80 bytes), but Windows NMTREEVIEW uses basic TVITEMW (56 bytes).
// Therefore PNMTREEVIEWW^.itemNew.hItem reads the wrong offset.
// Correct offset of itemNew.hItem in Windows NMTREEVIEW on 64-bit:
//   NMHDR(24) + action(4) + pad(4) + itemOld(56) + itemNew.mask(4) + pad(4) = 96
// On 32-bit:
//   NMHDR(12) + action(4) + itemOld(40) + itemNew.mask(4) = 60
{$IFDEF CPU64}
const NMTV_ITEMNEW_HITEM = 96;
{$ELSE}
const NMTV_ITEMNEW_HITEM = 60;
{$ENDIF}

function ViewerFromWnd(Wnd: HWND): TJsonViewer;
begin
  Result := TJsonViewer(GetWindowLongPtrW(Wnd, GWLP_USERDATA));
end;

function TreeWndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
var
  V: TJsonViewer;
begin
  V := ViewerFromWnd(GetParent(Wnd));
  if (Msg = WM_KEYDOWN) and Assigned(V) and V.HandleHotKey(WParam) then Exit(0);
  if Assigned(V) then
    Result := CallWindowProcW(V.FTreeOldProc, Wnd, Msg, WParam, LParam)
  else
    Result := DefWindowProcW(Wnd, Msg, WParam, LParam);
end;

function TabWndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
var
  V: TJsonViewer;
  Paint: TPaintStruct;
begin
  V := ViewerFromWnd(GetParent(Wnd));
  if Assigned(V) and V.FDark then
    case Msg of
      WM_ERASEBKGND: Exit(1);
      WM_PRINTCLIENT:
        begin
          V.PaintTabs(HDC(WParam));
          Exit(0);
        end;
      WM_PAINT:
        begin
          BeginPaint(Wnd, Paint);
          try
            V.PaintTabs(Paint.hdc);
          finally
            EndPaint(Wnd, Paint);
          end;
          Exit(0);
        end;
    end;
  if Assigned(V) and (Msg = WM_NOTIFY) then
    Exit(SendMessageW(V.FWnd, WM_NOTIFY, WParam, LParam));
  if Assigned(V) and (Msg = WM_CTLCOLOREDIT) then
  begin
    SetTextColor(HDC(WParam), V.FFilterTextColor);
    SetBkColor(HDC(WParam), V.FFilterBackColor);
    Exit(LRESULT(V.FFilterBrush));
  end;
  if Assigned(V) and (Msg = WM_KEYDOWN) and V.HandleHotKey(WParam) then Exit(0);
  if Assigned(V) and Assigned(V.FTabOldProc) then
    Result := CallWindowProcW(V.FTabOldProc, Wnd, Msg, WParam, LParam)
  else
    Result := DefWindowProcW(Wnd, Msg, WParam, LParam);
end;

function StatusWndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
var
  V: TJsonViewer;
  Paint: TPaintStruct;
begin
  V := ViewerFromWnd(GetParent(Wnd));
  if not Assigned(V) then Exit(DefWindowProcW(Wnd, Msg, WParam, LParam));
  if V.FDark then
    case Msg of
      WM_ERASEBKGND: Exit(1);
      WM_PRINTCLIENT:
        begin
          V.PaintStatus(HDC(WParam));
          Exit(0);
        end;
      WM_PAINT:
        begin
          BeginPaint(Wnd, Paint);
          try
            V.PaintStatus(Paint.hdc);
          finally
            EndPaint(Wnd, Paint);
          end;
          Exit(0);
        end;
    end;
  Result := CallWindowProcW(V.FStatusOldProc, Wnd, Msg, WParam, LParam);
end;

function GridWndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
var
  V: TJsonViewer;
  DrawResult: LRESULT;
begin
  V := ViewerFromWnd(GetParent(GetParent(Wnd)));
  if Assigned(V) and (Msg = WM_NOTIFY) and
    DrawGridHeader(Wnd, PNMHDR(LParam), V.FDark, DarkenColor(V.FFilterBackColor),
      V.FFilterTextColor, V.FSplitterColor, V.FHeaderFont, DrawResult) then
    Exit(DrawResult);
  if Assigned(V) and (Msg = WM_CTLCOLOREDIT) then
  begin
    SetTextColor(HDC(WParam), V.FFilterTextColor);
    SetBkColor(HDC(WParam), V.FFilterBackColor);
    Exit(LRESULT(V.FFilterBrush));
  end;
  if Assigned(V) and ((Msg = WM_HSCROLL) or (Msg = WM_VSCROLL) or
    (Msg = WM_MOUSEWHEEL)) then
    V.CloseCellEdit(True);
  if Assigned(V) and (Msg = WM_KEYDOWN) and V.HandleHotKey(WParam) then Exit(0);
  if Assigned(V) and Assigned(V.FGridOldProc) then
    Result := CallWindowProcW(V.FGridOldProc, Wnd, Msg, WParam, LParam)
  else
    Result := DefWindowProcW(Wnd, Msg, WParam, LParam);
end;

function TextWndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
var
  V: TJsonViewer;
  NavigationKey: Boolean;
begin
  V := ViewerFromWnd(GetParent(GetParent(Wnd)));
  if Assigned(V) and (Msg = WMU_TEXT_HIGHLIGHT) then
  begin
    V.FHighlightPending := False;
    V.HighlightVisibleText;
    Exit(0);
  end;
  if Assigned(V) and (Msg = WM_KEYDOWN) and V.HandleHotKey(WParam) then Exit(0);
  NavigationKey := (Msg = WM_KEYDOWN) and
    ((WParam = VK_UP) or (WParam = VK_DOWN) or
    (WParam = VK_PRIOR) or (WParam = VK_NEXT) or
    (WParam = VK_HOME) or (WParam = VK_END));
  if Assigned(V) and Assigned(V.FTextOldProc) then
    Result := CallWindowProcW(V.FTextOldProc, Wnd, Msg, WParam, LParam)
  else
    Result := DefWindowProcW(Wnd, Msg, WParam, LParam);
  if Assigned(V) and ((Msg = WM_VSCROLL) or (Msg = WM_MOUSEWHEEL) or
    NavigationKey or (Msg = EM_SCROLLCARET) or (Msg = EM_LINESCROLL) or
    (Msg = WM_SIZE) or (Msg = WM_PAINT)) then
    V.ScheduleTextHighlight;
end;

function EditorWndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
var
  V: TJsonViewer;
begin
  V := ViewerFromWnd(GetParent(GetParent(GetParent(Wnd))));
  if Assigned(V) then
  begin
    if Msg = WM_KEYDOWN then
    begin
      if WParam = VK_RETURN then begin V.CloseCellEdit(True); Exit(0); end;
      if WParam = VK_ESCAPE then begin V.CloseCellEdit(False); Exit(0); end;
      if V.HandleHotKey(WParam) then Exit(0);
    end;
    if Msg = WM_KILLFOCUS then
    begin
      V.CloseCellEdit(True);
      Exit(0);
    end;
  end;
  if Assigned(V) and Assigned(V.FEditorOldProc) then
    Result := CallWindowProcW(V.FEditorOldProc, Wnd, Msg, WParam, LParam)
  else
    Result := DefWindowProcW(Wnd, Msg, WParam, LParam);
end;

function MainWndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
var
  V: TJsonViewer;
  P: TPoint;
  Hdr: PNMHDR;
  DrawItem: PDrawItemStruct;
  Cmd: Integer;
  Menu, ThemeMenu: HMENU;
  Draw: PNMLVCUSTOMDRAW;
  R: TRect;
  CDIsSelected: Boolean;
  CDTextCol, CDBackCol: COLORREF;
  CDSubItem, CDAnchorW, CDRowIdx, CDAnchorX: Integer;
  CDS, CDAnchorPart, CDFracPart: UnicodeString;
  CDCellR, CDIntR, CDFracR: TRect;
  CDBrush: HBRUSH;
  CDSz: TSize;
begin
  V := ViewerFromWnd(Wnd);
  case Msg of
    WM_TIMER:
      if Assigned(V) and (WParam = FilterTimer) then
      begin
        KillTimer(Wnd, FilterTimer);
        V.ApplyFilters;
        Exit(0);
      end;
    WM_MEASUREITEM:
      if Assigned(V) and ((WParam = ViewerGroupID) or (WParam = ViewerFieldID)) then
      begin
        PMeasureItemStruct(LParam)^.itemHeight := ViewerPixels(Wnd, 22);
        Exit(1);
      end;
    WM_DRAWITEM:
      if Assigned(V) then
      begin
        DrawItem := PDrawItemStruct(LParam);
        case WParam of
          ViewerGroupID, ViewerFieldID:
            DrawComboItem(DrawItem^, GetStockObject(DEFAULT_GUI_FONT), V.FDark, V.FFilterBackColor, V.FFilterTextColor);
          ViewerClearID, ViewerRefreshID, ViewerSettingsID:
            DrawViewerButton(DrawItem^, V.FDark, V.FFilterBackColor, V.FFilterTextColor, V.FSplitterColor);
        else
          Exit(DefWindowProcW(Wnd, Msg, WParam, LParam));
        end;
        Exit(1);
      end;
    WM_CTLCOLORSTATIC:
      if Assigned(V) and V.FDark and (HWND(LParam) = V.FChrome.FilterSummary) then
      begin
        SetTextColor(HDC(WParam), V.FFilterTextColor);
        SetBkColor(HDC(WParam), V.FFilterBackColor);
        Exit(V.FFilterBrush);
      end;
    WM_CTLCOLOREDIT, WM_CTLCOLORLISTBOX:
      if Assigned(V) and V.FDark then
      begin
        SetTextColor(HDC(WParam), V.FFilterTextColor);
        SetBkColor(HDC(WParam), V.FFilterBackColor);
        Exit(V.FFilterBrush);
      end;
    $02E3:
      if Assigned(V) then begin V.ApplyFont(V.FFontSize); V.Layout; Exit(0); end;
    WM_SIZE:
      if Assigned(V) then begin V.Layout; Exit(0); end;
    WM_LBUTTONDOWN:
      if Assigned(V) and (SmallInt(LoWord(LParam)) >= V.FLayoutSplitter) and
        (SmallInt(LoWord(LParam)) < V.FLayoutSplitter + SPLITTER_WIDTH) then
      begin
        V.FSplitterDragOffset := SmallInt(LoWord(LParam)) - V.FLayoutSplitter;
        V.FDragging := True;
        SetCapture(Wnd);
        Exit(0);
      end;
    WM_MOUSEMOVE:
      if Assigned(V) and V.FDragging then
      begin
        V.FSplitter := Max(ViewerPixels(Wnd, 100), SmallInt(LoWord(LParam)) - V.FSplitterDragOffset);
        V.Layout;
        Exit(0);
      end;
    WM_LBUTTONUP:
      if Assigned(V) and V.FDragging then
      begin
        V.FDragging := False;
        ReleaseCapture;
        Exit(0);
      end;
    WM_CAPTURECHANGED:
      if Assigned(V) then V.FDragging := False;
    WM_SETCURSOR:
      if Assigned(V) and (LoWord(LParam) = HTCLIENT) then
      begin
        GetCursorPos(P);
        ScreenToClient(Wnd, P);
        if (P.X >= V.FLayoutSplitter) and (P.X < V.FLayoutSplitter + SPLITTER_WIDTH) then
        begin
          SetCursor(LoadCursor(0, IDC_SIZEWE));
          Exit(1);
        end;
      end;
    WM_NOTIFY:
      if Assigned(V) then
      begin
        Hdr := PNMHDR(LParam);
        if (Hdr^.idFrom = IDC_TREE) and (Integer(Hdr^.code) = TVN_ITEMEXPANDINGW) then
        begin
          if PNMTREEVIEWW(LParam)^.action = TVE_EXPAND then
            V.ExpandTreeNode(HTREEITEM(PPtrUInt(PByte(LParam) + NMTV_ITEMNEW_HITEM)^));
        end
        else if (Hdr^.idFrom = IDC_TREE) and (Integer(Hdr^.code) = NM_RCLICK) then
        begin
          GetCursorPos(P);
          V.ShowTreeMenu(P);
          Exit(1);
        end
        else if (Hdr^.idFrom = IDC_TREE) and (Integer(Hdr^.code) = TVN_SELCHANGEDW) then
          V.UpdateSelection
        else if (Hdr^.idFrom = IDC_TAB) and (Integer(Hdr^.code) = TCN_SELCHANGE) then
        begin
          if TabCtrl_GetCurSel(V.FTab) = 1 then
          begin
            if V.FTextNeedsUpdate then V.UpdateText(V.FCurrent);
            V.SyncGridToText;
          end
          else V.SyncTextToGrid;
          ShowWindow(V.FGrid, ChooseInt(TabCtrl_GetCurSel(V.FTab) = 0, SW_SHOW, SW_HIDE));
          ShowWindow(V.FText, ChooseInt(TabCtrl_GetCurSel(V.FTab) = 1, SW_SHOW, SW_HIDE));
          V.Layout;
          V.ScheduleTextHighlight;
          InvalidateRect(V.FTab, nil, False);
        end
        else if (Hdr^.idFrom = IDC_GRID) and (Integer(Hdr^.code) = LVN_COLUMNCLICK) then
        begin
          V.CloseCellEdit(True);
          V.SortGrid(PNMLISTVIEW(LParam)^.iSubItem);
        end
        else if (Hdr^.idFrom = IDC_GRID) and
          (Integer(Hdr^.code) = LVN_GETDISPINFOW) then
        begin
          with PNMLVDISPINFOW(LParam)^.item do
            if ((mask and LVIF_TEXT) <> 0) and
              Assigned(pszText) and (cchTextMax > 0) and
              (iItem >= 0) and (iItem < Length(V.FVisibleRows)) and
              (iSubItem >= 0) and
              (iSubItem < Length(V.FAllRows[V.FVisibleRows[iItem]])) then
              lstrcpynW(pszText,
                PWideChar(V.FAllRows[V.FVisibleRows[iItem], iSubItem]),
                cchTextMax);
          Exit(0);
        end
        else if (Hdr^.idFrom = IDC_GRID) and
          ((Integer(Hdr^.code) = NM_CLICK) or (Integer(Hdr^.code) = NM_RCLICK)) then
        begin
          V.SetCurrentCell(PNMITEMACTIVATE(LParam)^.iItem,
            PNMITEMACTIVATE(LParam)^.iSubItem);
          if (Integer(Hdr^.code) = NM_CLICK) and
            ((GetKeyState(VK_MENU) and $8000) <> 0) then V.OpenCurrentUrl;
        end
        else if (Hdr^.idFrom = IDC_GRID) and (Integer(Hdr^.code) = NM_DBLCLK) then
        begin
          V.SetCurrentCell(PNMITEMACTIVATE(LParam)^.iItem,
            PNMITEMACTIVATE(LParam)^.iSubItem);
          if V.FEditMode then
            V.BeginCellEdit(PNMITEMACTIVATE(LParam)^.iItem,
              PNMITEMACTIVATE(LParam)^.iSubItem)
          else
            V.NavigateGridRowToTree(PNMITEMACTIVATE(LParam)^.iItem);
        end
        else if (Hdr^.idFrom = IDC_GRID) and (Integer(Hdr^.code) = LVN_ITEMCHANGED) then
        begin
          if (PNMLISTVIEW(LParam)^.uNewState and LVIS_SELECTED) <> 0 then
            V.SetCurrentCell(PNMLISTVIEW(LParam)^.iItem, V.FCurrentColumn);
        end
        else if (Hdr^.idFrom = IDC_GRID) and (Integer(Hdr^.code) = NM_CUSTOMDRAW) then
        begin
          Draw := PNMLVCUSTOMDRAW(LParam);
          if Draw^.nmcd.dwDrawStage = CDDS_PREPAINT then Exit(CDRF_NOTIFYITEMDRAW);
          if Draw^.nmcd.dwDrawStage = CDDS_ITEMPREPAINT then
          begin
            if ListView_GetItemState(V.FGrid, Draw^.nmcd.dwItemSpec, LVIS_SELECTED) <> 0 then
              Draw^.nmcd.uItemState := Draw^.nmcd.uItemState and not CDIS_SELECTED;
            Exit(CDRF_NOTIFYSUBITEMDRAW);
          end;
          if Draw^.nmcd.dwDrawStage = (CDDS_ITEMPREPAINT or CDDS_SUBITEM) then
          begin
            CDIsSelected := ListView_GetItemState(V.FGrid,
              Draw^.nmcd.dwItemSpec, LVIS_SELECTED) <> 0;
            if CDIsSelected then
            begin
              CDTextCol := V.FSelectionTextColor;
              if (Integer(Draw^.nmcd.dwItemSpec) = V.FCurrentRow) and
                (Draw^.iSubItem = V.FCurrentColumn) then
                CDBackCol := V.FCurrentCellColor
              else
                CDBackCol := V.FSelectionBackColor;
            end
            else
            begin
              CDTextCol := V.FTextColor;
              if (Draw^.nmcd.dwItemSpec and 1) = 0 then
                CDBackCol := V.FBackColor
              else
                CDBackCol := V.FBackColor2;
            end;
            CDSubItem := Draw^.iSubItem;
            CDAnchorW := 0;
            if (CDSubItem >= 0) and (CDSubItem < Length(V.FDecimalAnchorWidths)) then
              CDAnchorW := V.FDecimalAnchorWidths[CDSubItem];
            if CDAnchorW > 0 then
            begin
              CDRowIdx := Integer(Draw^.nmcd.dwItemSpec);
              CDS := '';
              if (CDRowIdx >= 0) and (CDRowIdx < Length(V.FVisibleRows)) and
                 (CDSubItem < Length(V.FAllRows[V.FVisibleRows[CDRowIdx]])) then
                CDS := V.FAllRows[V.FVisibleRows[CDRowIdx], CDSubItem];
              CDCellR := Draw^.nmcd.rc;
              CDBrush := CreateSolidBrush(CDBackCol);
              FillRect(Draw^.nmcd.hdc, CDCellR, CDBrush);
              DeleteObject(CDBrush);
              SetBkMode(Draw^.nmcd.hdc, TRANSPARENT);
              SetTextColor(Draw^.nmcd.hdc, CDTextCol);
              if DecimalAnchorPart(CDS, CDAnchorPart) then
              begin
                FillChar(CDSz, SizeOf(CDSz), 0);
                GetTextExtentPoint32W(Draw^.nmcd.hdc, PWideChar(CDAnchorPart),
                  Length(CDAnchorPart), CDSz);
                CDAnchorX := CDCellR.Left + 6 + CDAnchorW;
                CDIntR := Rect(CDCellR.Left + 6, CDCellR.Top, CDAnchorX, CDCellR.Bottom);
                DrawTextW(Draw^.nmcd.hdc, PWideChar(CDAnchorPart), Length(CDAnchorPart),
                  CDIntR, DT_RIGHT or DT_VCENTER or DT_SINGLELINE);
                CDFracPart := Copy(CDS, Length(CDAnchorPart) + 1, MaxInt);
                if CDFracPart <> '' then
                begin
                  CDFracR := Rect(CDAnchorX, CDCellR.Top, CDCellR.Right - 2, CDCellR.Bottom);
                  DrawTextW(Draw^.nmcd.hdc, PWideChar(CDFracPart), Length(CDFracPart),
                    CDFracR, DT_LEFT or DT_VCENTER or DT_SINGLELINE);
                end;
              end else
              begin
                CDIntR := Rect(CDCellR.Left + 6, CDCellR.Top, CDCellR.Right - 2, CDCellR.Bottom);
                DrawTextW(Draw^.nmcd.hdc, PWideChar(CDS), Length(CDS), CDIntR,
                  DT_LEFT or DT_VCENTER or DT_SINGLELINE or DT_END_ELLIPSIS);
              end;
              Exit(CDRF_SKIPDEFAULT);
            end;
            Draw^.clrText := CDTextCol;
            Draw^.clrTextBk := CDBackCol;
            Exit(CDRF_DODEFAULT);
          end;
        end;
        Exit(0);
      end;
    WM_MOUSEWHEEL:
      if Assigned(V) and ((GetKeyState(VK_CONTROL) and $8000) <> 0) then
      begin
        V.SetFontSize(V.FFontSize + ChooseInt(SmallInt(HiWord(WParam)) > 0, 1, -1));
        Exit(0);
      end;
    WM_KEYDOWN:
      if Assigned(V) and V.HandleHotKey(WParam) then Exit(0);
    WM_CONTEXTMENU:
      if Assigned(V) then
      begin
        P.X := SmallInt(LoWord(LParam));
        P.Y := SmallInt(HiWord(LParam));
        if HWND(WParam) = V.FTree then
        begin
          if (P.X = -1) and (P.Y = -1) then
          begin
            P.X := 12;
            P.Y := 12;
            ClientToScreen(V.FTree, P);
          end;
          V.ShowTreeMenu(P);
          Exit(0);
        end;
        Menu := CreatePopupMenu;
        try
          AppendMenuW(Menu, MF_STRING, IDM_COPY, PWideChar(Tr('Copy', 'Копировать')));
          AppendMenuW(Menu, MF_STRING, IDM_COPY_ROWS, PWideChar(Tr('Copy row(s) (Shift+C)', 'Копировать строки (Shift+C)')));
          AppendMenuW(Menu, MF_STRING, IDM_COPY_COLUMN, PWideChar(Tr('Copy column (Ctrl+C)', 'Копировать столбец (Ctrl+C)')));
          AppendMenuW(Menu, MF_STRING, IDM_COPY_AS_JSON, PWideChar(Tr('Copy as JSON', 'Копировать как JSON')));
          AppendMenuW(Menu, MF_STRING, IDM_COPY_JSONPATH, PWideChar(Tr('Copy JSONPath', 'Копировать JSONPath')));
          AppendMenuW(Menu, MF_SEPARATOR, 0, nil);
          AppendMenuW(Menu, MF_STRING, IDM_HIDE_COLUMN, PWideChar(Tr('Hide column', 'Скрыть столбец')));
          AppendMenuW(Menu, MF_STRING, IDM_SHOW_COLUMNS, PWideChar(Tr('Show all columns (Ctrl+Space)', 'Показать все столбцы (Ctrl+Space)')));
          AppendMenuW(Menu, MF_SEPARATOR, 0, nil);
          AppendMenuW(Menu, MF_STRING or ChooseInt(V.FFilterVisible, MF_CHECKED, 0), IDM_FILTERS, PWideChar(Tr('Filters', 'Фильтры')));
          AppendMenuW(Menu, MF_STRING or ChooseInt(V.FEditMode, MF_CHECKED, 0) or
            ChooseInt(Assigned(V.FGroupedRoot), MF_GRAYED, 0), IDM_EDIT_MODE, PWideChar(Tr('Edit mode (Ctrl+E)', 'Редактирование (Ctrl+E)')));
          ThemeMenu := CreatePopupMenu;
          if ThemeMenu <> 0 then
          begin
            AppendMenuW(ThemeMenu, MF_STRING or ChooseInt(V.FThemeMode = tmTotalCommander,
              MF_CHECKED, 0), IDM_THEME_TC, PWideChar(Tr('Follow Total Commander', 'Как в Total Commander')));
            AppendMenuW(ThemeMenu, MF_STRING or ChooseInt(V.FThemeMode = tmLight,
              MF_CHECKED, 0), IDM_THEME_LIGHT, PWideChar(Tr('Light', 'Светлая')));
            AppendMenuW(ThemeMenu, MF_STRING or ChooseInt(V.FThemeMode = tmDark,
              MF_CHECKED, 0), IDM_THEME_DARK, PWideChar(Tr('Dark', 'Тёмная')));
            if not AppendMenuW(Menu, MF_POPUP, UINT_PTR(ThemeMenu), PWideChar(Tr('Theme', 'Тема'))) then
              DestroyMenu(ThemeMenu);
          end;
          TrackPopupMenu(Menu, TPM_RIGHTBUTTON, P.X, P.Y, 0, Wnd, nil);
        finally
          DestroyMenu(Menu);
        end;
        Exit(0);
      end;
    WM_COMMAND:
      if Assigned(V) then
      begin
        Cmd := LoWord(WParam);
        case Cmd of
          ViewerGroupID: if HiWord(WParam) = CBN_SELCHANGE then
          begin
            Cmd := SendMessageW(V.FChrome.GroupBy, CB_GETCURSEL, 0, 0);
            if Cmd = 0 then V.SetTreeGrouping(False, '')
            else if (Cmd > 0) and (Cmd <= V.FGroupFields.Count) then
              V.SetTreeGrouping(True, V.FGroupFields[Cmd - 1]);
          end;
          ViewerFieldID: if HiWord(WParam) = CBN_SELCHANGE then V.SyncFilterEditor;
          ViewerPatternID: if (HiWord(WParam) = EN_CHANGE) and not V.FUpdatingPattern then
          begin
            // Keep the pending text associated with the field being edited.
            V.ReadFilterEditor;
            if SetTimer(Wnd, FilterTimer, ViewerFilterDelay, nil) = 0 then V.ApplyFilters;
          end;
          ViewerClearID: V.ClearFilters;
          ViewerRefreshID: V.RefreshFile;
          ViewerSettingsID: V.OpenSettings;
          IDM_COPY: V.CopySelectedCell;
          IDM_COPY_ROWS: V.CopyRows;
          IDM_COPY_COLUMN: V.CopyColumn;
          IDM_COPY_AS_JSON: V.CopyAsJson;
          IDM_COPY_JSONPATH: V.CopyJsonPath;
          IDM_HIDE_COLUMN: V.HideColumn(V.FCurrentColumn);
          IDM_SHOW_COLUMNS: V.ShowAllColumns;
          IDM_FILTERS: begin V.FFilterVisible := not V.FFilterVisible; V.Layout; end;
          IDM_EDIT_MODE: V.ToggleEditMode;
          IDM_THEME_TC: V.SetThemeMode(tmTotalCommander);
          IDM_THEME_LIGHT: V.SetThemeMode(tmLight);
          IDM_THEME_DARK: V.SetThemeMode(tmDark);
        end;
        Exit(0);
      end;
    WM_PRINTCLIENT, WM_ERASEBKGND:
      if Assigned(V) then
      begin
        GetClientRect(Wnd, R);
        SetBkColor(HDC(WParam), V.FSplitterColor);
        ExtTextOutW(HDC(WParam), 0, 0, ETO_OPAQUE, @R, nil, 0, nil);
        Exit(1);
      end;
  end;
  Result := DefWindowProcW(Wnd, Msg, WParam, LParam);
end;

procedure RegisterViewerClass;
var
  WC: WNDCLASSEXW;
begin
  if ClassRegistered then Exit;
  FillChar(WC, SizeOf(WC), 0);
  WC.cbSize := SizeOf(WC);
  WC.lpfnWndProc := @MainWndProc;
  WC.hInstance := HInstance;
  WC.hCursor := LoadCursor(0, IDC_ARROW);
  WC.hbrBackground := COLOR_WINDOW + 1;
  WC.lpszClassName := CLASS_NAME;
  ClassRegistered := RegisterClassExW(WC) <> 0;
end;

constructor TJsonViewer.Create(ParentWin: HWND; const FileName: UnicodeString; ShowFlags: Integer; MaxSize: Int64);
var
  IC: tagINITCOMMONCONTROLSEX;
  Malformed: Boolean;
  StatusParts: array[0..6] of Integer;
begin
  inherited Create;
  FSplitter := ReadSettingInt('splitter-position', 200);
  if FSplitter < 110 then FSplitter := 110;
  FSplitterDragOffset := 0;
  FSortColumn := -1;
  FCurrentRow := 0;
  FCurrentColumn := 0;
  FFilterBrush := 0;
  FFilterFields := TStringList.Create;
  FFilterFields.CaseSensitive := True;
  FMaxSize := MaxSize;
  FCellEditor := 0;
  FEditMode := False;
  FDirty := False;
  FClosingEditor := False;
  FColoredFirstLine := -1;
  FTextNeedsUpdate := True;
  FFileName := FileName;
  FFilterVisible := ReadSettingInt('filter-row', 1) <> 0;
  FThemeMode := ConfiguredThemeMode;
  FShowFlags := ShowFlags;
  FDark := (FThemeMode = tmDark) or
    ((FThemeMode = tmTotalCommander) and ((ShowFlags and lcp_darkmode) <> 0));
  if not LoadJsonFile(FileName, MaxSize,
    ReadSettingInt('parse-mode', 0), FRoot, FEncoding, Malformed) then
    raise EViewerMessage.CreateText(Tr('JSON could not be loaded', 'Не удалось загрузить JSON'));
  FMalformed := Malformed;

  IC.dwSize := SizeOf(IC);
  IC.dwICC := ICC_TREEVIEW_CLASSES or ICC_LISTVIEW_CLASSES or ICC_TAB_CLASSES or ICC_BAR_CLASSES;
  InitCommonControlsEx(IC);
  LoadLibraryW('msftedit.dll');
  RegisterViewerClass;

  FWnd := CreateWindowExW(WS_EX_CONTROLPARENT, CLASS_NAME, 'jsontab',
    WS_CHILD or WS_VISIBLE or WS_CLIPCHILDREN, 0, 0, 100, 100,
    ParentWin, 0, HInstance, nil);
  if FWnd = 0 then RaiseLastOSError;
  SetWindowLongPtrW(FWnd, GWLP_USERDATA, PtrInt(Self));

  FTree := CreateViewerTree(FWnd, IDC_TREE);
  FTreeOldProc := WNDPROC(SetWindowLongPtrW(FTree, GWLP_WNDPROC, PtrInt(@TreeWndProc)));
  FTab := CreateViewerTabs(FWnd, IDC_TAB, WS_CLIPCHILDREN or WS_CLIPSIBLINGS);
  FTabOldProc := WNDPROC(SetWindowLongPtrW(FTab, GWLP_WNDPROC, PtrInt(@TabWndProc)));

  FGrid := CreateViewerGrid(FTab, IDC_GRID, 0);
  FGridOldProc := WNDPROC(SetWindowLongPtrW(FGrid, GWLP_WNDPROC, PtrInt(@GridWndProc)));
  ListView_SetExtendedListViewStyle(FGrid, LVS_EX_FULLROWSELECT or
    ChooseInt(ReadSettingInt('disable-grid-lines', 0) = 0, LVS_EX_GRIDLINES, 0) or
    LVS_EX_DOUBLEBUFFER or LVS_EX_HEADERDRAGDROP);
  FText := CreateViewerText(FTab, IDC_TEXT);
  SendMessageW(FText, EM_SETUNDOLIMIT, 0, 0);
  FTextDocument := RichEditDocument(FText);
  FTextOldProc := WNDPROC(SetWindowLongPtrW(FText, GWLP_WNDPROC, PtrInt(@TextWndProc)));
  FStatus := CreateStatusWindowW(WS_CHILD or WS_VISIBLE, nil, FWnd, IDC_STATUS);
  FStatusOldProc := WNDPROC(SetWindowLongPtrW(FStatus, GWLP_WNDPROC, PtrInt(@StatusWndProc)));
  StatusParts[0] := 95;
  StatusParts[1] := 140;
  StatusParts[2] := 200;
  StatusParts[3] := 400;
  StatusParts[4] := 500;
  StatusParts[5] := -1;
  SendMessageW(FStatus, SB_SETPARTS, 6, LPARAM(@StatusParts[0]));
  CreateViewerChrome(FWnd, FChrome, GetStockObject(DEFAULT_GUI_FONT));
  ApplyFont(ReadSettingInt('font-size', 16));
  TabCtrl_SetCurSel(FTab, ReadSettingInt('tab-no', 0));
  ShowWindow(FGrid, ChooseInt(TabCtrl_GetCurSel(FTab) = 0, SW_SHOW, SW_HIDE));
  ShowWindow(FText, ChooseInt(TabCtrl_GetCurSel(FTab) = 1, SW_SHOW, SW_HIDE));
  FSavedSplitter := FSplitter;
  FSavedFilterVisible := FFilterVisible;
  FSavedFontSize := FFontSize;
  FSavedTabNo := TabCtrl_GetCurSel(FTab);
  ApplyTheme;
  BuildGroupChoices;
  BuildTree;
  Layout;
end;

destructor TJsonViewer.Destroy;
begin
  CloseCellEdit(False);
  if FSplitter <> FSavedSplitter then WriteSettingInt('splitter-position', FSplitter);
  if FFilterVisible <> FSavedFilterVisible then WriteSettingInt('filter-row', Ord(FFilterVisible));
  if FFontSize <> FSavedFontSize then WriteSettingInt('font-size', FFontSize);
  if TabCtrl_GetCurSel(FTab) <> FSavedTabNo then WriteSettingInt('tab-no', TabCtrl_GetCurSel(FTab));
  if FWnd <> 0 then KillTimer(FWnd, FilterTimer);
  FGroupFields.Free;
  FFilterFields.Free;
  if IsWindow(FStatus) and Assigned(FStatusOldProc) then
    SetWindowLongPtrW(FStatus, GWLP_WNDPROC, PtrInt(@FStatusOldProc));
  SetWindowLongPtrW(FWnd, GWLP_USERDATA, 0);
  if FTabFont <> 0 then DeleteObject(FTabFont);
  if FHeaderFont <> 0 then DeleteObject(FHeaderFont);
  if FFont <> 0 then DeleteObject(FFont);
  if FFilterBrush <> 0 then DeleteObject(FFilterBrush);
  FreeAndNil(FGroupedRoot);
  FreeAndNil(FRoot);
  FTextDocument := nil;
  if IsWindow(FWnd) then DestroyWindow(FWnd);
  inherited Destroy;
end;

procedure TJsonViewer.AddTreeNode(Parent: HTREEITEM; Data: TJSONData; const Caption: UnicodeString);
var
  TVI: TVINSERTSTRUCTW;
  Item: HTREEITEM;
begin
  FillChar(TVI, SizeOf(TVI), 0);
  TVI.hParent := Parent;
  TVI.hInsertAfter := TVI_LAST;
  TVI.item.mask := TVIF_TEXT or TVIF_PARAM;
  TVI.item.pszText := PWideChar(Caption);
  TVI.item.lParam := LPARAM(Data);
  Item := HTREEITEM(SendMessageW(FTree, TVM_INSERTITEMW, 0, LPARAM(@TVI)));
  if Assigned(Data) and (Data.JSONType in [jtArray, jtObject]) and (Data.Count > 0) then
  begin
    FillChar(TVI, SizeOf(TVI), 0);
    TVI.hParent := Item;
    TVI.hInsertAfter := TVI_LAST;
    TVI.item.mask := TVIF_TEXT or TVIF_PARAM;
    TVI.item.pszText := '...';
    TVI.item.lParam := 0;
    SendMessageW(FTree, TVM_INSERTITEMW, 0, LPARAM(@TVI));
  end;
end;

procedure TJsonViewer.ExpandTreeNode(Item: HTREEITEM);
var
  TV: TVITEMW;
  Data: TJSONData;
  Child: HTREEITEM;
  I: Integer;
begin
  FillChar(TV, SizeOf(TV), 0);
  TV.mask := TVIF_PARAM;
  TV.hItem := Item;
  if SendMessageW(FTree, TVM_GETITEMW, 0, LPARAM(@TV)) = 0 then Exit;
  Data := TJSONData(TV.lParam);
  if not Assigned(Data) then Exit;
  Child := HTREEITEM(SendMessageW(FTree, TVM_GETNEXTITEM, TVGN_CHILD, LPARAM(Item)));
  if Child = nil then Exit;
  FillChar(TV, SizeOf(TV), 0);
  TV.mask := TVIF_PARAM;
  TV.hItem := Child;
  SendMessageW(FTree, TVM_GETITEMW, 0, LPARAM(@TV));
  if TV.lParam <> 0 then Exit;
  SendMessageW(FTree, TVM_DELETEITEM, 0, LPARAM(Child));
  if Data.Count > 64 then LockWindowUpdate(FTree);
  try
    if Data.JSONType = jtArray then
      for I := 0 to Data.Count - 1 do
        AddTreeNode(Item, Data.Items[I], Format('[%d]', [I]))
    else
      for I := 0 to Data.Count - 1 do
        AddTreeNode(Item, Data.Items[I], UTF8Decode(TJSONObject(Data).Names[I]));
  finally
    if Data.Count > 64 then
    begin
      LockWindowUpdate(0);
      InvalidateRect(FTree, nil, True);
    end;
  end;
end;

procedure TJsonViewer.BuildTree;
var
  Root, Child: HTREEITEM;
begin
  SendMessageW(FTree, TVM_DELETEITEM, 0, LPARAM(TVI_ROOT));
  if Assigned(FGroupedRoot) then
    AddTreeNode(TVI_ROOT, FGroupedRoot, Tr('Group by: ', 'Группировка: ') + UTF8Decode(FGroupField))
  else if FMalformed then
    AddTreeNode(TVI_ROOT, FRoot, Tr('<<malformed>>', '<<ошибка формата>>'))
  else
    AddTreeNode(TVI_ROOT, FRoot, Tr('<<root>>', '<<корень>>'));
  Root := HTREEITEM(SendMessageW(FTree, TVM_GETNEXTITEM, TVGN_ROOT, 0));
  if Root <> nil then
  begin
    SendMessageW(FTree, TVM_EXPAND, TVE_EXPAND, LPARAM(Root));
    if Assigned(FGroupedRoot) or (FRoot.JSONType = jtArray) then Child := Root
    else Child := HTREEITEM(SendMessageW(FTree, TVM_GETNEXTITEM, TVGN_CHILD, LPARAM(Root)));
    if Child <> nil then
      SendMessageW(FTree, TVM_SELECTITEM, TVGN_CARET, LPARAM(Child));
  end;
  UpdateSelection;
end;

procedure TJsonViewer.ShowTreeMenu(const Position: TPoint);
var
  Fields: TStringList;
  Menu: HMENU;
  FieldIndex, Command: Integer;
  Caption: UnicodeString;
begin
  Fields := GroupableFields(FRoot);
  try
    if Fields.Count = 0 then Exit;
    Menu := CreatePopupMenu;
    if Menu = 0 then Exit;
    try
      AppendMenuW(Menu, MF_STRING or ChooseInt(not Assigned(FGroupedRoot), MF_CHECKED, 0),
        1, PWideChar(Tr('File order', 'Порядок файла')));
      AppendMenuW(Menu, MF_SEPARATOR, 0, nil);
      for FieldIndex := 0 to Fields.Count - 1 do
      begin
        Caption := Tr('Group by ', 'Группировать по ') + UTF8Decode(StringReplace(Fields[FieldIndex],
          '&', '&&', [rfReplaceAll]));
        if Fields[FieldIndex] = '' then Caption := Tr('Group by (empty key)', 'Группировать по пустому ключу');
        AppendMenuW(Menu, MF_STRING or ChooseInt(Assigned(FGroupedRoot) and
          (Fields[FieldIndex] = FGroupField), MF_CHECKED, 0), FieldIndex + 2, PWideChar(Caption));
      end;
      Command := Integer(TrackPopupMenu(Menu, TPM_RETURNCMD or TPM_NONOTIFY or TPM_RIGHTBUTTON,
        Position.X, Position.Y, 0, FWnd, nil));
      if Command = 1 then SetTreeGrouping(False, '')
      else if Command >= 2 then SetTreeGrouping(True, Fields[Command - 2]);
    finally
      DestroyMenu(Menu);
    end;
  finally
    Fields.Free;
  end;
end;

procedure TJsonViewer.SetTreeGrouping(Enabled: Boolean; const Field: TJSONStringType);
var
  OldRoot, NewRoot: TJSONObject;
begin
  if Enabled = Assigned(FGroupedRoot) then
    if not Enabled or (Field = FGroupField) then Exit;
  CloseCellEdit(True);
  if IsWindow(FCellEditor) then Exit;
  NewRoot := nil;
  if Enabled then
  begin
    NewRoot := GroupJsonRecords(FRoot, Field);
    FEditMode := False;
  end;
  OldRoot := FGroupedRoot;
  FGroupedRoot := NewRoot;
  FGroupField := Field;
  try
    BuildGroupChoices;
    BuildTree;
  finally
    OldRoot.Free;
  end;
end;

function TJsonViewer.SelectedData: TJSONData;
var
  TV: TVITEMW;
  Item: HTREEITEM;
begin
  Result := nil;
  Item := HTREEITEM(SendMessageW(FTree, TVM_GETNEXTITEM, TVGN_CARET, 0));
  if Item = nil then Exit;
  FillChar(TV, SizeOf(TV), 0);
  TV.mask := TVIF_PARAM;
  TV.hItem := Item;
  if SendMessageW(FTree, TVM_GETITEMW, 0, LPARAM(@TV)) <> 0 then
    Result := TJSONData(TV.lParam);
  if Assigned(FGroupedRoot) and (Result = FGroupedRoot) then Result := FRoot;
end;

procedure AddColumn(Grid: HWND; Index: Integer; const Name: UnicodeString);
var
  Col: LVCOLUMNW;
begin
  FillChar(Col, SizeOf(Col), 0);
  Col.mask := LVCF_TEXT or LVCF_WIDTH or LVCF_SUBITEM;
  Col.pszText := PWideChar(Name);
  Col.cx := 140;
  Col.iSubItem := Index;
  SendMessageW(Grid, LVM_INSERTCOLUMNW, Index, LPARAM(@Col));
end;

procedure GetCellTextW(Grid: HWND; Row, Col: Integer; Buffer: PWideChar;
  Count: Integer);
var
  Item: LVITEMW;
begin
  FillChar(Item, SizeOf(Item), 0);
  Item.iSubItem := Col;
  Item.pszText := Buffer;
  Item.cchTextMax := Count;
  SendMessageW(Grid, LVM_GETITEMTEXTW, Row, LPARAM(@Item));
end;

procedure GetHeaderText(Header: HWND; Index: Integer; Buffer: PWideChar; Count: Integer);
var
  Item: HDITEMW;
begin
  FillChar(Item, SizeOf(Item), 0);
  Item.mask := HDI_TEXT;
  Item.pszText := Buffer;
  Item.cchTextMax := Count;
  SendMessageW(Header, HDM_GETITEMW, Index, LPARAM(@Item));
end;

procedure TJsonViewer.BuildGrid(Data: TJSONData);
var
  I, J, ColCount: Integer;
  Obj: TJSONObject;
  Names: TStringList;
  Value, Missing: UnicodeString;
begin
  FCurrentRow := 0;
  FCurrentColumn := 0;
  FSortColumn := -1;
  FScalarArray := False;
  SendMessageW(FGrid, WM_SETREDRAW, 0, 0);
  ListView_SetItemCount(FGrid, 0);
  SetLength(FAllRows, 0);
  SetLength(FAllRowData, 0);
  SetLength(FVisibleRowData, 0);
  SetLength(FVisibleRows, 0);
  while Header_GetItemCount(ListView_GetHeader(FGrid)) > 0 do
    ListView_DeleteColumn(FGrid, 0);
  Missing := ReadSetting('missing-attribute-value', 'N/A');
  if Data.JSONType = jtArray then
  begin
    Names := TStringList.Create;
    try
      Names.CaseSensitive := True;
      for I := 0 to Data.Count - 1 do
        if Data.Items[I].JSONType = jtObject then
        begin
          Obj := TJSONObject(Data.Items[I]);
          for J := 0 to Obj.Count - 1 do
            if Names.IndexOf(Obj.Names[J]) < 0 then Names.Add(Obj.Names[J]);
          if ReadSettingInt('skip-attributes-scan', 0) <> 0 then Break;
        end;
      FScalarArray := Names.Count = 0;
      if FScalarArray then
      begin
        Names.Add('Element');
        AddColumn(FGrid, 0, Tr('Element', 'Элемент'));
      end
      else for J := 0 to Names.Count - 1 do AddColumn(FGrid, J, UTF8Decode(Names[J]));
      SetLength(FAllRowData, Data.Count);
      SetLength(FAllRows, Data.Count, Names.Count);
      for I := 0 to Data.Count - 1 do
      begin
        FAllRowData[I] := Data.Items[I];
        for J := 0 to Names.Count - 1 do
        begin
          if FScalarArray then
            Value := JsonDisplayValue(Data.Items[I])
          else if Data.Items[I].JSONType = jtObject then
          begin
            Obj := TJSONObject(Data.Items[I]);
            ColCount := Obj.IndexOfName(Names[J]);
            if ColCount >= 0 then Value := JsonDisplayValue(Obj.Items[ColCount])
            else Value := Missing;
          end else Value := Missing;
          FAllRows[I, J] := Value;
        end;
      end;
    finally
      Names.Free;
    end;
  end
  else if Data.JSONType = jtObject then
  begin
    AddColumn(FGrid, 0, Tr('Attribute', 'Атрибут'));
    AddColumn(FGrid, 1, Tr('Value', 'Значение'));
    Obj := TJSONObject(Data);
    SetLength(FAllRowData, Obj.Count);
    SetLength(FAllRows, Obj.Count, 2);
    for I := 0 to Obj.Count - 1 do
    begin
      FAllRowData[I] := Obj.Items[I];
      FAllRows[I, 0] := UTF8Decode(Obj.Names[I]);
      FAllRows[I, 1] := JsonDisplayValue(Obj.Items[I]);
    end;
  end
  else
  begin
    SetLength(FAllRowData, 1);
    SetLength(FAllRows, 1, 1);
    FAllRowData[0] := Data;
    AddColumn(FGrid, 0, Tr('Value', 'Значение'));
    FAllRows[0, 0] := JsonDisplayValue(Data);
  end;
  BuildFilterChoices;
  ApplyFilters;
  SendMessageW(FGrid, WM_SETREDRAW, 1, 0);
  InvalidateRect(FGrid, nil, True);
end;

procedure TJsonViewer.ApplyTextPalette;
var
  Format: CHARFORMAT2W;
begin
  FillChar(Format, SizeOf(Format), 0);
  Format.cbSize := SizeOf(Format);
  Format.dwMask := CFM_COLOR or CFM_BOLD;
  Format.crTextColor := FJsonTextColor;
  SendMessageW(FText, EM_SETCHARFORMAT, SCF_ALL, LPARAM(@Format));
  SendMessageW(FText, EM_SETCHARFORMAT, SCF_DEFAULT, LPARAM(@Format));
  FColoredFirstLine := -1;
end;

procedure TJsonViewer.UpdateText(Data: TJSONData);
var
  S: UnicodeString;
  I: Integer;
  Filtered: TJSONData;
begin
  if not Assigned(Data) then Exit;
  Filtered := nil;
  try
    if Length(FVisibleRows) < Length(FAllRows) then
      case Data.JSONType of
        jtArray:
          begin
            Filtered := TJSONArray.Create;
            for I := 0 to High(FVisibleRows) do
              TJSONArray(Filtered).Add(FVisibleRowData[I].Clone);
          end;
        jtObject:
          begin
            Filtered := TJSONObject.Create;
            for I := 0 to High(FVisibleRows) do
              TJSONObject(Filtered).Add(TJSONObject(Data).Names[FVisibleRows[I]],
                FVisibleRowData[I].Clone);
          end;
      end;
    if Assigned(Filtered) then S := JsonPretty(Filtered)
    else if (Length(FVisibleRows) = 0) and (Length(FAllRows) > 0) then S := ''
    else S := JsonPretty(Data);
  finally
    Filtered.Free;
  end;
  SetWindowTextW(FText, PWideChar(S));
  ApplyViewerFontToText(FText, FFont);
  ApplyTextPalette;
  FTextNeedsUpdate := False;
  ScheduleTextHighlight;
end;

procedure TJsonViewer.UpdateStatus(Data: TJSONData; Rows: Integer);
var
  S: UnicodeString;
  Item, Sib: HTREEITEM;
  ChildNo: Integer;
begin
  S := ' ' + FEncoding;
  SendMessageW(FStatus, SB_SETTEXTW, 0, LPARAM(PWideChar(S)));
  Item := HTREEITEM(SendMessageW(FTree, TVM_GETNEXTITEM, TVGN_CARET, 0));
  ChildNo := 1;
  if Item <> nil then
  begin
    Sib := HTREEITEM(SendMessageW(FTree, TVM_GETNEXTITEM, TVGN_PREVIOUS, LPARAM(Item)));
    while Sib <> nil do
    begin
      Inc(ChildNo);
      Sib := HTREEITEM(SendMessageW(FTree, TVM_GETNEXTITEM, TVGN_PREVIOUS, LPARAM(Sib)));
    end;
  end;
  S := Format(' %d', [ChildNo]);
  SendMessageW(FStatus, SB_SETTEXTW, 1, LPARAM(PWideChar(S)));
  case Data.JSONType of
    jtBoolean: S := Tr(' BOOLEAN', ' ЛОГИЧ.');
    jtNumber: S := Tr(' NUMBER', ' ЧИСЛО');
    jtString: S := Tr(' STRING', ' СТРОКА');
    jtArray: S := Tr(' ARRAY', ' МАССИВ');
    jtObject: S := Tr(' OBJECT', ' ОБЪЕКТ');
  else
    S := ' ' + JsonTypeName(Data);
  end;
  SendMessageW(FStatus, SB_SETTEXTW, 2, LPARAM(PWideChar(S)));
  S := UnicodeFormat(Tr(' Rows: %d/%d', ' Строки: %d/%d'), [Rows, Length(FAllRows)]);
  SendMessageW(FStatus, SB_SETTEXTW, 3, LPARAM(PWideChar(S)));
  if (FCurrentRow >= 0) and (FCurrentColumn >= 0) then
    S := Format(' %d:%d', [FCurrentRow + 1, FCurrentColumn + 1])
  else
    S := '';
  SendMessageW(FStatus, SB_SETTEXTW, 4, LPARAM(PWideChar(S)));
  UpdateEditStatus;
end;

procedure TJsonViewer.UpdateSelection;
begin
  CloseCellEdit(True);
  FCurrent := SelectedData;
  if not Assigned(FCurrent) then Exit;
  BuildGrid(FCurrent);
end;

procedure TJsonViewer.Layout;
var
  R, SR: TRect;
  L: TViewerLayout;
  ControlHeight, ContentHeight: Integer;
begin
  if (FStatus = 0) or (FChrome.Settings = 0) then Exit;
  CloseCellEdit(True);
  GetClientRect(FWnd, R);
  SendMessageW(FStatus, WM_SIZE, 0, 0);
  GetClientRect(FStatus, SR);
  L := LayoutViewerChrome(FWnd, FChrome, FSplitter, SR.Bottom, FFilterVisible);
  FLayoutSplitter := L.LeftWidth;
  ControlHeight := L.RowHeight + L.Margin;
  MoveWindow(FTree, L.Margin, ControlHeight, Max(0, L.LeftWidth - L.Margin),
    Max(0, L.StatusTop - ControlHeight), True);
  MoveWindow(FTab, L.RightX, L.Margin, L.RightWidth, Max(0, L.StatusTop - L.Margin), True);
  ControlHeight := L.FilterBottom - L.Margin;
  ContentHeight := Max(0, L.StatusTop - L.FilterBottom);
  MoveWindow(FGrid, 0, ControlHeight, L.RightWidth, ContentHeight, True);
  MoveWindow(FText, 0, ControlHeight, L.RightWidth, ContentHeight, True);
end;

procedure TJsonViewer.PaintTabs(DC: HDC);
var
  Bounds, Tab, CaptionRect: TRect;
  Caption: array[0..127] of WideChar;
  Item: TCITEMW;
  I, SavedDC: Integer;
  Selected: Boolean;
begin
  SavedDC := SaveDC(DC);
  try
    GetClientRect(FTab, Bounds);
    FillColor(DC, Bounds, FBackColor);
    SetBkMode(DC, TRANSPARENT);
    SelectObject(DC, FTabFont);
    SetTextColor(DC, FTextColor);
    for I := 0 to TabCtrl_GetItemCount(FTab) - 1 do
    begin
      if SendMessageW(FTab, TCM_GETITEMRECT, I, LPARAM(@Tab)) = 0 then Continue;
      Selected := I = TabCtrl_GetCurSel(FTab);
      if Selected then
      begin
        FillColor(DC, Tab, FFilterBackColor);
        FillColor(DC, Rect(Tab.Left, Tab.Bottom - 2, Tab.Right, Tab.Bottom),
          FSelectionBackColor);
      end
      else
        FillColor(DC, Tab, FBackColor2);
      FillChar(Item, SizeOf(Item), 0);
      Caption[0] := #0;
      Item.mask := TCIF_TEXT;
      Item.pszText := @Caption[0];
      Item.cchTextMax := Length(Caption);
      SendMessageW(FTab, TCM_GETITEMW, I, LPARAM(@Item));
      CaptionRect := Tab;
      if Selected then Dec(CaptionRect.Bottom, 2);
      DrawTextW(DC, @Caption[0], -1, CaptionRect,
        DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
    end;
  finally
    RestoreDC(DC, SavedDC);
  end;
end;

procedure TJsonViewer.PaintStatus(DC: HDC);
var
  Bounds, Part: TRect;
  Caption: UnicodeString;
  I, SavedDC: Integer;
begin
  SavedDC := SaveDC(DC);
  try
    GetClientRect(FStatus, Bounds);
    FillColor(DC, Bounds, FBackColor2);
    SetBkMode(DC, TRANSPARENT);
    SelectObject(DC, SendMessageW(FStatus, WM_GETFONT, 0, 0));
    SetTextColor(DC, FTextColor);
    for I := 0 to SendMessageW(FStatus, SB_GETPARTS, 0, 0) - 1 do
    begin
      if SendMessageW(FStatus, SB_GETRECT, I, LPARAM(@Part)) = 0 then Continue;
      SetLength(Caption, LoWord(SendMessageW(FStatus, SB_GETTEXTLENGTHW, I, 0)) + 1);
      SendMessageW(FStatus, SB_GETTEXTW, I, LPARAM(PWideChar(Caption)));
      FillColor(DC, Rect(Part.Left, Part.Top, Part.Left + 1, Part.Bottom), FSplitterColor);
      Inc(Part.Left, 3);
      DrawTextW(DC, PWideChar(Caption), -1, Part,
        DT_LEFT or DT_VCENTER or DT_SINGLELINE or DT_END_ELLIPSIS or DT_NOPREFIX);
    end;
  finally
    RestoreDC(DC, SavedDC);
  end;
end;

procedure TJsonViewer.SetThemeMode(Mode: TThemeMode);
begin
  FThemeMode := Mode;
  WriteSetting('theme-mode', THEME_NAMES[Ord(Mode)]);
  UpdateShowFlags(FShowFlags);
end;

procedure TJsonViewer.UpdateShowFlags(ShowFlags: Integer);
var
  Dark: Boolean;
begin
  FShowFlags := ShowFlags;
  Dark := (FThemeMode = tmDark) or
    ((FThemeMode = tmTotalCommander) and ((ShowFlags and lcp_darkmode) <> 0));
  if Dark = FDark then Exit;
  FDark := Dark;
  ApplyTheme;
end;

procedure TJsonViewer.ApplyTheme;
var
  ThemeClass: PWideChar;
begin
  if FDark then
  begin
    FTextColor := ReadSettingInt('text-color-dark', RGB(220, 220, 220));
    FBackColor := ReadSettingInt('back-color-dark', RGB(32, 32, 32));
    FBackColor2 := ReadSettingInt('back-color2-dark', RGB(52, 52, 52));
    FFilterTextColor := ReadSettingInt('filter-text-color-dark', RGB(255, 255, 255));
    FFilterBackColor := ReadSettingInt('filter-back-color-dark', RGB(60, 60, 60));
    FCurrentCellColor := ReadSettingInt('current-cell-back-color-dark', RGB(32, 62, 62));
    FSelectionTextColor := ReadSettingInt('selection-text-color-dark', RGB(220, 220, 220));
    FSelectionBackColor := ReadSettingInt('selection-back-color-dark', RGB(72, 102, 102));
    FSplitterColor := ReadSettingInt('splitter-color-dark', RGB(64, 64, 64));
    FJsonTextColor := ReadSettingInt('json-text-color-dark', RGB(220, 220, 220));
    FJsonKeyColor := ReadSettingInt('json-key-color-dark', RGB(219, 161, 239));
    FJsonStringColor := ReadSettingInt('json-string-color-dark', RGB(165, 211, 143));
    FJsonBooleanColor := ReadSettingInt('json-boolean-color-dark', RGB(130, 185, 255));
    FJsonNullColor := ReadSettingInt('json-null-color-dark', RGB(242, 163, 149));
  end
  else
  begin
    FTextColor := ReadSettingInt('text-color', RGB(0, 0, 0));
    FBackColor := ReadSettingInt('back-color', RGB(255, 255, 255));
    FBackColor2 := ReadSettingInt('back-color2', RGB(240, 240, 240));
    FFilterTextColor := ReadSettingInt('filter-text-color', RGB(0, 0, 0));
    FFilterBackColor := ReadSettingInt('filter-back-color', RGB(240, 240, 240));
    FCurrentCellColor := ReadSettingInt('current-cell-back-color', RGB(70, 96, 166));
    FSelectionTextColor := ReadSettingInt('selection-text-color', RGB(255, 255, 255));
    FSelectionBackColor := ReadSettingInt('selection-back-color', RGB(10, 36, 106));
    FSplitterColor := ReadSettingInt('splitter-color', GetSysColor(COLOR_BTNFACE));
    FJsonTextColor := ReadSettingInt('json-text-color', RGB(0, 0, 0));
    FJsonKeyColor := ReadSettingInt('json-key-color', RGB(128, 0, 128));
    FJsonStringColor := ReadSettingInt('json-string-color', RGB(0, 128, 0));
    FJsonBooleanColor := ReadSettingInt('json-boolean-color', RGB(0, 0, 255));
    FJsonNullColor := ReadSettingInt('json-null-color', RGB(255, 0, 0));
  end;
  if FFilterBrush <> 0 then DeleteObject(FFilterBrush);
  FFilterBrush := CreateSolidBrush(FFilterBackColor);
  ThemeClass := nil;
  if FDark then ThemeClass := 'DarkMode_Explorer';
  SetControlTheme(FTree, ThemeClass, nil);
  SetControlTheme(FGrid, ThemeClass, nil);
  SetControlTheme(ListView_GetHeader(FGrid), ThemeClass, nil);
  SetControlTheme(FText, ThemeClass, nil);
  ListView_SetExtendedListViewStyleEx(FGrid, LVS_EX_GRIDLINES,
    ChooseInt(not FDark and (ReadSettingInt('disable-grid-lines', 0) = 0), LVS_EX_GRIDLINES, 0));
  ThemeViewerChrome(FChrome, FDark);
  SendMessageW(FTree, TVM_SETBKCOLOR, 0, FBackColor);
  SendMessageW(FTree, TVM_SETTEXTCOLOR, 0, FTextColor);
  InvalidateRect(FTree, nil, True);
  ListView_SetBkColor(FGrid, FBackColor);
  ListView_SetTextBkColor(FGrid, FBackColor);
  ListView_SetTextColor(FGrid, FTextColor);
  SendMessageW(FText, EM_SETBKGNDCOLOR, 0, FBackColor);
  ApplyTextPalette;
  ScheduleTextHighlight;
  InvalidateRect(FStatus, nil, True);
  InvalidateRect(FGrid, nil, True);
  InvalidateRect(ListView_GetHeader(FGrid), nil, True);
  InvalidateRect(FTab, nil, True);
  InvalidateRect(FWnd, nil, True);
end;

procedure SetClipboard(const S: UnicodeString);
var
  H: HGLOBAL;
  P: Pointer;
begin
  H := GlobalAlloc(GMEM_MOVEABLE, (Length(S) + 1) * SizeOf(WideChar));
  P := GlobalLock(H);
  Move(PWideChar(S)^, P^, (Length(S) + 1) * SizeOf(WideChar));
  GlobalUnlock(H);
  if OpenClipboard(0) then
  try
    EmptyClipboard;
    SetClipboardData(CF_UNICODETEXT, H);
    H := 0;
  finally
    CloseClipboard;
  end;
  if H <> 0 then GlobalFree(H);
end;

procedure TJsonViewer.CopySelectedCell;
var
  Row: Integer;
  Buf: array[0..4095] of WideChar;
begin
  if GetFocus = FText then begin SendMessageW(FText, WM_COPY, 0, 0); Exit; end;
  Row := ListView_GetNextItem(FGrid, -1, LVNI_SELECTED);
  if Row < 0 then Row := 0;
  Buf[0] := #0;
  GetCellTextW(FGrid, Row, FCurrentColumn, @Buf[0], Length(Buf));
  SetClipboard(Buf);
end;

procedure TJsonViewer.CopyRows;
var
  Row, Col, Cols: Integer;
  Buf: array[0..4095] of WideChar;
  S, Delimiter: UnicodeString;
begin
  S := '';
  Delimiter := ReadSetting('column-delimiter', #9);
  Cols := Header_GetItemCount(ListView_GetHeader(FGrid));
  Row := ListView_GetNextItem(FGrid, -1, LVNI_SELECTED);
  if Row < 0 then Row := 0;
  while Row < ListView_GetItemCount(FGrid) do
  begin
    for Col := 0 to Cols - 1 do
    begin
      Buf[0] := #0;
      GetCellTextW(FGrid, Row, Col, @Buf[0], Length(Buf));
      if Col > 0 then S := S + Delimiter;
      S := S + Buf;
    end;
    Row := ListView_GetNextItem(FGrid, Row, LVNI_SELECTED);
    if Row >= 0 then S := S + #13#10 else Break;
  end;
  SetClipboard(S);
end;

procedure TJsonViewer.CopyColumn;
var
  Row: Integer;
  Buf: array[0..4095] of WideChar;
  S: UnicodeString;
begin
  S := '';
  for Row := 0 to ListView_GetItemCount(FGrid) - 1 do
  begin
    Buf[0] := #0;
    GetCellTextW(FGrid, Row, FCurrentColumn, @Buf[0], Length(Buf));
    if Row > 0 then S := S + #13#10;
    S := S + Buf;
  end;
  SetClipboard(S);
end;

function IsOriginalJsonNumber(const S: UnicodeString): Boolean;
var
  I, Dots: Integer;
begin
  Dots := 0;
  Result := True;
  for I := 1 to Length(S) do
  begin
    if S[I] = '.' then Inc(Dots)
    else if not (S[I] in ['0'..'9']) then Exit(False);
  end;
  Result := Dots < 2;
end;

function IsJsonNumberValue(const S: UnicodeString): Boolean;
var
  I: Integer;
begin
  Result := False;
  if S = '' then Exit;
  I := 1;
  if S[I] = '-' then
  begin
    Inc(I);
    if I > Length(S) then Exit;
  end;
  if S[I] = '0' then
    Inc(I)
  else
  begin
    if not (S[I] in ['1'..'9']) then Exit;
    repeat Inc(I) until (I > Length(S)) or not (S[I] in ['0'..'9']);
  end;
  if (I <= Length(S)) and (S[I] = '.') then
  begin
    Inc(I);
    if (I > Length(S)) or not (S[I] in ['0'..'9']) then Exit;
    repeat Inc(I) until (I > Length(S)) or not (S[I] in ['0'..'9']);
  end;
  if (I <= Length(S)) and (S[I] in ['e', 'E']) then
  begin
    Inc(I);
    if (I <= Length(S)) and (S[I] in ['+', '-']) then Inc(I);
    if (I > Length(S)) or not (S[I] in ['0'..'9']) then Exit;
    repeat Inc(I) until (I > Length(S)) or not (S[I] in ['0'..'9']);
  end;
  Result := I > Length(S);
end;

procedure TJsonViewer.CopyAsJson;
var
  Row, Col, Cols, GridType, I: Integer;
  Buf, NameBuf: array[0..4095] of WideChar;
  Arr: TJSONArray;
  Obj: TJSONObject;
  Root: TJSONData;
  S, Value, Name, Missing: UnicodeString;
  D: Double;
  FS: TFormatSettings;
  ColOrder: array of Integer;

  procedure AddArrayValue(A: TJSONArray; const V: UnicodeString);
  begin
    if (V = 'true') or (V = 'false') then A.Add(V = 'true')
    else if IsOriginalJsonNumber(V) and TryStrToFloat(V, D, FS) then A.Add(D)
    else A.Add(UTF8Encode(V));
  end;

  procedure AddObjectValue(O: TJSONObject; const N, V: UnicodeString);
  begin
    if (V = 'true') or (V = 'false') then
      O.Add(UTF8Encode(N), V = 'true')
    else if IsOriginalJsonNumber(V) and TryStrToFloat(V, D, FS) then
      O.Add(UTF8Encode(N), D)
    else O.Add(UTF8Encode(N), UTF8Encode(V));
  end;
begin
  Cols := Header_GetItemCount(ListView_GetHeader(FGrid));
  if Cols = 0 then Exit;
  if ListView_GetNextItem(FGrid, -1, LVNI_SELECTED) < 0 then
  begin
    SetClipboard('');
    Exit;
  end;
  case FCurrent.JSONType of
    jtArray: GridType := Ord(FScalarArray);
    jtObject: GridType := 2;
  else
    GridType := 3;
  end;
  if GridType = 3 then
  begin
    CopySelectedCell;
    Exit;
  end;
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Missing := ReadSetting('missing-attribute-value', 'N/A');
  SetLength(ColOrder, Cols);
  SendMessageW(ListView_GetHeader(FGrid), HDM_GETORDERARRAY, Cols, LPARAM(@ColOrder[0]));
  if GridType in [0, 1] then Root := TJSONArray.Create else Root := TJSONObject.Create;
  try
    Arr := nil;
    Obj := nil;
    if Root is TJSONArray then Arr := TJSONArray(Root);
    Row := ListView_GetNextItem(FGrid, -1, LVNI_SELECTED);
    while Row >= 0 do
    begin
      if GridType = 0 then
      begin
        Obj := TJSONObject.Create;
        for I := 0 to Cols - 1 do
        begin
          Col := ColOrder[I];
          if ListView_GetColumnWidth(FGrid, Col) = 0 then Continue;
          NameBuf[0] := #0;
          GetHeaderText(ListView_GetHeader(FGrid), Col, @NameBuf[0], Length(NameBuf));
          Buf[0] := #0;
          GetCellTextW(FGrid, Row, Col, @Buf[0], Length(Buf));
          Name := NameBuf;
          Value := Buf;
          if Value <> Missing then AddObjectValue(Obj, Name, Value);
        end;
        Arr.Add(Obj);
      end
      else if GridType = 1 then
      begin
        Buf[0] := #0;
        GetCellTextW(FGrid, Row, 0, @Buf[0], Length(Buf));
        AddArrayValue(Arr, Buf);
      end
      else
      begin
        NameBuf[0] := #0;
        Buf[0] := #0;
        GetCellTextW(FGrid, Row, 0, @NameBuf[0], Length(NameBuf));
        GetCellTextW(FGrid, Row, 1, @Buf[0], Length(Buf));
        TJSONObject(Root).Add(UTF8Encode(UnicodeString(NameBuf)),
          UTF8Encode(UnicodeString(Buf)));
      end;
      Row := ListView_GetNextItem(FGrid, Row, LVNI_SELECTED);
    end;
    if (GetKeyState(VK_CONTROL) and $8000) <> 0 then S := UTF8Decode(Root.AsJSON)
    else S := UTF8Decode(Root.FormatJSON([], 2));
    SetClipboard(S);
  finally
    Root.Free;
  end;
end;

procedure TJsonViewer.CopyJsonPath;
var
  Indices: TJsonIndexPath;
  Data: TJSONData;
  Index: Integer;
  Path: UTF8String;
begin
  if not FindJsonIndexPath(FRoot, FCurrent, Indices) then Exit;
  Data := FRoot;
  Path := '$';
  for Index in Indices do
  begin
    if Data.JSONType = jtArray then
      Path := Path + Format('[%d]', [Index])
    else
      Path := Path + '.' + TJSONObject(Data).Names[Index];
    Data := Data.Items[Index];
  end;
  SetClipboard(UTF8Decode(Path));
end;

procedure TJsonViewer.BuildGroupChoices;
var
  I, Selected: Integer;
  Caption: UnicodeString;
begin
  FGroupFields.Free;
  FGroupFields := GroupableFields(FRoot);
  SendMessageW(FChrome.GroupBy, CB_RESETCONTENT, 0, 0);
  Caption := Tr('Group by: file order', 'Группировка: порядок файла');
  SendMessageW(FChrome.GroupBy, CB_ADDSTRING, 0, LPARAM(PWideChar(Caption)));
  Selected := 0;
  for I := 0 to FGroupFields.Count - 1 do
  begin
    Caption := UTF8Decode(FGroupFields[I]);
    if Caption = '' then Caption := Tr('(empty key)', '(пустой ключ)');
    if Assigned(FGroupedRoot) and (FGroupFields[I] = FGroupField) then
    begin
      Selected := I + 1;
      Caption := Tr('Group by: ', 'Группировка: ') + Caption;
    end;
    SendMessageW(FChrome.GroupBy, CB_ADDSTRING, 0, LPARAM(PWideChar(Caption)));
  end;
  SendMessageW(FChrome.GroupBy, CB_SETCURSEL, Selected, 0);
  EnableWindow(FChrome.GroupBy, FGroupFields.Count <> 0);
end;

procedure TJsonViewer.BuildFilterChoices;
var
  I, Count, Selected: Integer;
  NameBuf: array[0..4095] of WideChar;
  Previous: UTF8String;
  Caption: UnicodeString;
begin
  I := SendMessageW(FChrome.Field, CB_GETCURSEL, 0, 0);
  Previous := '';
  if (I >= 0) and (I < Length(FColumnFilters)) then Previous := FColumnFilters[I];
  SendMessageW(FChrome.Field, CB_RESETCONTENT, 0, 0);
  Count := Header_GetItemCount(ListView_GetHeader(FGrid));
  SetLength(FColumnFilters, Count);
  Selected := 0;
  for I := 0 to Count - 1 do
  begin
    NameBuf[0] := #0;
    GetHeaderText(ListView_GetHeader(FGrid), I, @NameBuf[0], Length(NameBuf));
    Caption := NameBuf;
    FColumnFilters[I] := UTF8Encode(Caption);
    if FColumnFilters[I] = Previous then Selected := I;
    if Caption = '' then Caption := Tr('(empty key)', '(пустой ключ)');
    SendMessageW(FChrome.Field, CB_ADDSTRING, 0, LPARAM(PWideChar(Caption)));
  end;
  if Count > 0 then SendMessageW(FChrome.Field, CB_SETCURSEL, Selected, 0);
  EnableWindow(FChrome.Field, Count > 0);
  EnableWindow(FChrome.Pattern, Count > 0);
  SyncFilterEditor;
end;

procedure TJsonViewer.SyncFilterEditor;
var
  Column, Index: Integer;
  Pattern: UnicodeString;
begin
  Column := SendMessageW(FChrome.Field, CB_GETCURSEL, 0, 0);
  Pattern := '';
  if (Column >= 0) and (Column < Length(FColumnFilters)) then
  begin
    Index := FFilterFields.IndexOf(FColumnFilters[Column]);
    if Index >= 0 then Pattern := FPatterns[Index];
  end;
  FUpdatingPattern := True;
  try
    SetWindowTextW(FChrome.Pattern, PWideChar(Pattern));
  finally
    FUpdatingPattern := False;
  end;
end;

procedure TJsonViewer.ReadFilterEditor;
var Column, Index: Integer;
begin
  KillTimer(FWnd, FilterTimer);
  Column := SendMessageW(FChrome.Field, CB_GETCURSEL, 0, 0);
  if (Column < 0) or (Column >= Length(FColumnFilters)) then Exit;
  Index := FFilterFields.IndexOf(FColumnFilters[Column]);
  if Index < 0 then
  begin
    Index := FFilterFields.Add(FColumnFilters[Column]);
    SetLength(FPatterns, FFilterFields.Count);
  end;
  FPatterns[Index] := ControlText(FChrome.Pattern);
end;

procedure TJsonViewer.ClearFilters;
begin
  KillTimer(FWnd, FilterTimer);
  FFilterFields.Clear;
  FPatterns := nil;
  SyncFilterEditor;
  ApplyFilters;
end;

procedure TJsonViewer.RefreshFile;
var
  NewRoot, OldRoot: TJSONData;
  NewGroup, OldGroup: TJSONObject;
  Encoding: UnicodeString;
  Malformed: Boolean;
  Choice: Integer;
begin
  CloseCellEdit(True);
  if IsWindow(FCellEditor) then Exit;
  if FDirty then
  begin
    Choice := MessageBoxW(FWnd,
      PWideChar(Tr('Save changes before refreshing?', 'Сохранить изменения перед обновлением?')),
      'JsonTab', MB_YESNOCANCEL or MB_ICONWARNING);
    if (Choice = IDCANCEL) or ((Choice = IDYES) and not SaveChanges) then Exit;
  end;
  NewRoot := nil;
  if not LoadJsonFile(FFileName, FMaxSize, ReadSettingInt('parse-mode', 0),
    NewRoot, Encoding, Malformed) then
  begin
    NewRoot.Free;
    MessageBoxW(FWnd,
      PWideChar(Tr('Could not reload the JSON file.', 'Не удалось перечитать файл JSON.')),
      'JsonTab', MB_OK or MB_ICONERROR);
    Exit;
  end;
  NewGroup := nil;
  if Assigned(FGroupedRoot) then
    try
      NewGroup := GroupJsonRecords(NewRoot, FGroupField);
    except
      NewRoot.Free;
      raise;
    end;
  OldRoot := FRoot;
  OldGroup := FGroupedRoot;
  FRoot := NewRoot;
  FGroupedRoot := NewGroup;
  FEncoding := Encoding;
  FMalformed := Malformed;
  FDirty := False;
  try
    BuildGroupChoices;
    BuildTree;
  finally
    OldGroup.Free;
    OldRoot.Free;
  end;
end;

procedure TJsonViewer.OpenSettings;
begin
  if not ShowSettingsDialog(FWnd, FDark) then Exit;
  FThemeMode := ConfiguredThemeMode;
  FDark := (FThemeMode = tmDark) or
    ((FThemeMode = tmTotalCommander) and ((FShowFlags and lcp_darkmode) <> 0));
  ApplyFont(ReadSettingInt('font-size', 16));
  FSavedFontSize := FFontSize;
  ApplyTheme;
  ApplyFilters;
  Layout;
end;

procedure TJsonViewer.UpdateVirtualGrid;
begin
  CloseCellEdit(True);
  ListView_SetItemCount(FGrid, Length(FVisibleRows));
  InvalidateRect(FGrid, nil, True);
end;

procedure TJsonViewer.AutoSizeVisibleColumns;
const
  HEADER_PADDING = 24;
  CELL_PADDING = 16;
  MAX_MEASURED_ROWS = 1000;
var
  DC: HDC;
  OldFont: HGDIOBJ;
  Col, Row, HeaderWidth, CellWidth, DesiredWidth, MaxWidth,
    RowsToMeasure, ConfiguredMaxWidth, ColCount: Integer;
  Size: TSize;
  HeaderBuf: array[0..4095] of WideChar;
  S, AnchorPart: UnicodeString;
  DoDecimalAlign: Boolean;
  ColAnchorW: array of Integer;   // max measured anchor width per column (pixels)
  ColHasNonNum: array of Boolean; // true if any non-numeric value found in column
begin
  DC := GetDC(FGrid);
  if DC = 0 then Exit;
  OldFont := SelectObject(DC, FFont);
  DoDecimalAlign := ReadSettingInt('decimal-align', 0) <> 0;
  try
    RowsToMeasure := Length(FVisibleRows);
    if RowsToMeasure > MAX_MEASURED_ROWS then RowsToMeasure := MAX_MEASURED_ROWS;
    ColCount := Header_GetItemCount(ListView_GetHeader(FGrid));
    ConfiguredMaxWidth := ReadSettingInt('max-column-width', 300);
    SetLength(ColAnchorW, ColCount);
    SetLength(ColHasNonNum, ColCount);
    SetLength(FDecimalAnchorWidths, ColCount);
    for Col := 0 to ColCount - 1 do
    begin
      ColAnchorW[Col] := 0;
      ColHasNonNum[Col] := False;
      FDecimalAnchorWidths[Col] := 0;
    end;
    for Col := 0 to ColCount - 1 do
    begin
      if ListView_GetColumnWidth(FGrid, Col) = 0 then Continue;
      HeaderBuf[0] := #0;
      GetHeaderText(ListView_GetHeader(FGrid), Col, @HeaderBuf[0], Length(HeaderBuf));
      S := HeaderBuf;
      FillChar(Size, SizeOf(Size), 0);
      SelectObject(DC, FHeaderFont);
      GetTextExtentPoint32W(DC, PWideChar(S), Length(S), Size);
      SelectObject(DC, FFont);
      HeaderWidth := Size.cx + HEADER_PADDING;
      DesiredWidth := HeaderWidth;
      MaxWidth := HeaderWidth * 3;
      if (ColCount > 1) and (ConfiguredMaxWidth > 0) and
        (ConfiguredMaxWidth < MaxWidth) then
        MaxWidth := ConfiguredMaxWidth;
      if MaxWidth < HeaderWidth then MaxWidth := HeaderWidth;
      for Row := 0 to RowsToMeasure - 1 do
      begin
        S := FAllRows[FVisibleRows[Row], Col];
        FillChar(Size, SizeOf(Size), 0);
        GetTextExtentPoint32W(DC, PWideChar(S), Length(S), Size);
        CellWidth := Size.cx + CELL_PADDING;
        if CellWidth > DesiredWidth then DesiredWidth := CellWidth;
        if DesiredWidth >= MaxWidth then
        begin
          DesiredWidth := MaxWidth;
          Break;
        end;
      end;
      if DoDecimalAlign then
        for Row := 0 to RowsToMeasure - 1 do
        begin
          S := FAllRows[FVisibleRows[Row], Col];
          if S = '' then Continue;
          if DecimalAnchorPart(S, AnchorPart) then
          begin
            FillChar(Size, SizeOf(Size), 0);
            GetTextExtentPoint32W(DC, PWideChar(AnchorPart), Length(AnchorPart), Size);
            if Size.cx > ColAnchorW[Col] then ColAnchorW[Col] := Size.cx;
          end else
            ColHasNonNum[Col] := True;
        end;
      ListView_SetColumnWidth(FGrid, Col, DesiredWidth);
    end;
    if DoDecimalAlign then
      for Col := 0 to ColCount - 1 do
        if not ColHasNonNum[Col] and (ColAnchorW[Col] > 0) then
          FDecimalAnchorWidths[Col] := ColAnchorW[Col] + CELL_PADDING div 2;
  finally
    SelectObject(DC, OldFont);
    ReleaseDC(FGrid, DC);
  end;
end;

procedure TJsonViewer.ApplyFilters;
var
  I, J, N, Index: Integer;
  Filters: array of UnicodeString;
  RowData: TJsonDataArray;
  TempRows: TIntegerArray;
  Match, CaseSensitive: Boolean;
  Summary: UnicodeString;

  function CompareRows(A, B: Integer): Integer;
  begin
    Result := NaturalCompare(FAllRows[A, FSortColumn],
      FAllRows[B, FSortColumn]);
    if FSortDescending then Result := -Result;
  end;

  procedure MergeSort(Left, Right: Integer);
  var
    Middle, A, B, K: Integer;
  begin
    if Left >= Right then Exit;
    Middle := (Left + Right) div 2;
    MergeSort(Left, Middle);
    MergeSort(Middle + 1, Right);
    A := Left;
    B := Middle + 1;
    K := Left;
    while (A <= Middle) and (B <= Right) do
    begin
      if CompareRows(FVisibleRows[A], FVisibleRows[B]) <= 0 then
      begin
        TempRows[K] := FVisibleRows[A];
        Inc(A);
      end
      else
      begin
        TempRows[K] := FVisibleRows[B];
        Inc(B);
      end;
      Inc(K);
    end;
    while A <= Middle do
    begin
      TempRows[K] := FVisibleRows[A];
      Inc(A);
      Inc(K);
    end;
    while B <= Right do
    begin
      TempRows[K] := FVisibleRows[B];
      Inc(B);
      Inc(K);
    end;
    for K := Left to Right do FVisibleRows[K] := TempRows[K];
  end;
begin
  FSearchText := '';
  SetLength(Filters, Length(FColumnFilters));
  Summary := '';
  for J := 0 to High(Filters) do
  begin
    Index := FFilterFields.IndexOf(FColumnFilters[J]);
    if Index < 0 then Continue;
    Filters[J] := FPatterns[Index];
    if Filters[J] <> '' then
    begin
      if Summary <> '' then Summary := Summary + ' | ';
      Summary := Summary + UTF8Decode(FColumnFilters[J]) + ': ' + Filters[J];
    end;
  end;
  SetWindowTextW(FChrome.FilterSummary, PWideChar(Summary));
  CaseSensitive := ReadSettingInt('filter-case-sensitive', 0) <> 0;
  N := 0;
  SetLength(FVisibleRows, Length(FAllRows));
  for I := 0 to High(FAllRows) do
  begin
    Match := True;
    for J := 0 to High(Filters) do
      Match := Match and MatchesFilter(FAllRows[I, J], Filters[J], CaseSensitive);
    if Match then
    begin
      FVisibleRows[N] := I;
      Inc(N);
    end;
  end;
  SetLength(FVisibleRows, N);
  if (FSortColumn >= 0) and (FSortColumn < Length(Filters)) then
  begin
    SetLength(TempRows, N);
    MergeSort(0, N - 1);
  end;
  SetLength(RowData, N);
  for I := 0 to N - 1 do RowData[I] := FAllRowData[FVisibleRows[I]];
  FVisibleRowData := RowData;
  UpdateVirtualGrid;
  AutoSizeVisibleColumns;
  if N = 0 then FCurrentRow := -1
  else if FCurrentRow >= N then FCurrentRow := N - 1;
  if Assigned(FCurrent) then
  begin
    UpdateStatus(FCurrent, N);
    FTextNeedsUpdate := True;
    if TabCtrl_GetCurSel(FTab) = 1 then UpdateText(FCurrent);
  end;
end;

procedure TJsonViewer.HideColumn(Column: Integer);
begin
  if (Column < 0) or (Column >= Length(FColumnFilters)) then Exit;
  ListView_SetColumnWidth(FGrid, Column, 0);
end;

procedure TJsonViewer.ShowAllColumns;
var
  I: Integer;
begin
  for I := 0 to Length(FColumnFilters) - 1 do
    ListView_SetColumnWidth(FGrid, I, 1);
  AutoSizeVisibleColumns;
end;

procedure TJsonViewer.SetFontSize(NewSize: Integer);
begin
  if (NewSize < 10) or (NewSize > 48) or (NewSize = FFontSize) then Exit;
  ApplyFont(NewSize);
  AutoSizeVisibleColumns;
  Layout;
  InvalidateRect(ListView_GetHeader(FGrid), nil, True);
end;

procedure TJsonViewer.ApplyFont(NewSize: Integer);
begin
  if (NewSize < 10) or (NewSize > 48) then NewSize := 16;
  FFontSize := NewSize;
  if FTabFont <> 0 then DeleteObject(FTabFont);
  if FHeaderFont <> 0 then DeleteObject(FHeaderFont);
  if FFont <> 0 then DeleteObject(FFont);
  FFont := CreateFontW(ViewerPixels(FWnd, FFontSize), 0, 0, 0, ConfiguredFontWeight, 0, 0, 0,
    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
    DEFAULT_QUALITY, DEFAULT_PITCH, PWideChar(ReadSetting('font', 'Arial')));
  FHeaderFont := CreateFontW(ViewerPixels(FWnd, FFontSize), 0, 0, 0, FW_BOLD, 0, 0, 0,
    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
    DEFAULT_QUALITY, DEFAULT_PITCH, PWideChar(ReadSetting('font', 'Arial')));
  FTabFont := CreateFontW(ViewerPixels(FWnd, FFontSize), 0, 0, 0, FW_NORMAL, 0, 0, 0,
    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
    DEFAULT_QUALITY, DEFAULT_PITCH, PWideChar(ReadSetting('font', 'Arial')));
  SendMessageW(FTree, WM_SETFONT, FFont, 1);
  SendMessageW(FTab, WM_SETFONT, FTabFont, 1);
  SendMessageW(FGrid, WM_SETFONT, FFont, 1);
  ApplyViewerFontToText(FText, FFont);
end;

procedure TJsonViewer.ScheduleTextHighlight;
begin
  if FHighlightPending or FHighlighting or FTextNeedsUpdate or
    not Assigned(FTextDocument) or
    ((GetWindowLongPtrW(FText, GWL_STYLE) and WS_VISIBLE) = 0) then Exit;
  FHighlightPending := PostMessageW(FText, WMU_TEXT_HIGHLIGHT, 0, 0);
end;

procedure TJsonViewer.HighlightVisibleText;
begin
  if FTextNeedsUpdate then Exit;
  HighlightVisibleJson(FText, FTextDocument, FJsonKeyColor, FJsonStringColor,
    FJsonBooleanColor, FJsonNullColor, ReadSettingInt('font-use-bold', 0) <> 0,
    FHighlighting, FColoredFirstLine, FColoredLastLine);
end;

procedure TJsonViewer.OpenCurrentUrl;
var
  Row: Integer;
  Buf: array[0..4095] of WideChar;
  S: UnicodeString;
begin
  Row := ListView_GetNextItem(FGrid, -1, LVNI_SELECTED);
  if Row < 0 then Exit;
  Buf[0] := #0;
  GetCellTextW(FGrid, Row, FCurrentColumn, @Buf[0], Length(Buf));
  S := Buf;
  if Pos('://', S) = 0 then
  begin
    if Pos('.', S) = 0 then Exit;
    S := 'https://' + S;
  end;
  ShellExecuteW(0, 'open', PWideChar(S), nil, nil, SW_SHOW);
end;

procedure TJsonViewer.SelectTreeData(Data: TJSONData);
var
  Root: TJSONData;
  Path: TJsonIndexPath;
  Item, Child: HTREEITEM;
  Index, Sibling: Integer;
begin
  if not Assigned(Data) then Exit;
  Item := HTREEITEM(SendMessageW(FTree, TVM_GETNEXTITEM, TVGN_ROOT, 0));
  if Item = nil then Exit;
  Root := FRoot;
  if Assigned(FGroupedRoot) then Root := FGroupedRoot;
  if Data <> FRoot then
  begin
    if not FindJsonIndexPath(Root, Data, Path) then Exit;
    for Index in Path do
    begin
      SendMessageW(FTree, TVM_EXPAND, TVE_EXPAND, LPARAM(Item));
      Child := HTREEITEM(SendMessageW(FTree, TVM_GETNEXTITEM, TVGN_CHILD, LPARAM(Item)));
      for Sibling := 1 to Index do
      begin
        if Child = nil then Exit;
        Child := HTREEITEM(SendMessageW(FTree, TVM_GETNEXTITEM, TVGN_NEXT, LPARAM(Child)));
      end;
      if Child = nil then Exit;
      Item := Child;
    end;
  end;
  SendMessageW(FTree, TVM_SELECTITEM, TVGN_CARET, LPARAM(Item));
  SendMessageW(FTree, TVM_ENSUREVISIBLE, 0, LPARAM(Item));
  SetFocus(FTree);
end;

procedure TJsonViewer.NavigateGridRowToTree(Row: Integer);
begin
  if (Row >= 0) and (Row < Length(FVisibleRowData)) then
    SelectTreeData(FVisibleRowData[Row]);
end;

procedure TJsonViewer.SyncGridToText;
var
  Row, P: Integer;
  FullText, Part: UnicodeString;
  Buf: array[0..65535] of WideChar;
  CellBuf: array[0..4095] of WideChar;
begin
  Row := ListView_GetNextItem(FGrid, -1, LVNI_SELECTED);
  if (Row < 0) or (Row >= Length(FVisibleRowData)) then Exit;
  CellBuf[0] := #0;
  GetCellTextW(FGrid, Row, FCurrentColumn, @CellBuf[0], Length(CellBuf));
  Part := CellBuf;
  if (Part = '') or (Part = '[Object]') or (Part = '[Array]') then
    Part := JsonPretty(FVisibleRowData[Row]);
  Buf[0] := #0;
  GetWindowTextW(FText, Buf, Length(Buf));
  FullText := Buf;
  P := Pos(Part, FullText);
  if P > 0 then
  begin
    SendMessageW(FText, EM_SETSEL, P - 1, P - 1 + Length(Part));
    SendMessageW(FText, EM_SCROLLCARET, 0, 0);
  end;
end;

procedure TJsonViewer.SyncTextToGrid;
var
  SelStart, SelEnd, I, J, Rows, Cols: Integer;
  FullText, Selected, Cell: UnicodeString;
  TextBuf: array[0..65535] of WideChar;
  CellBuf: array[0..4095] of WideChar;
begin
  SelStart := 0;
  SelEnd := 0;
  SendMessageW(FText, EM_GETSEL, WPARAM(@SelStart), LPARAM(@SelEnd));
  if SelEnd <= SelStart then Exit;
  TextBuf[0] := #0;
  GetWindowTextW(FText, TextBuf, Length(TextBuf));
  FullText := TextBuf;
  Selected := Copy(FullText, SelStart + 1, SelEnd - SelStart);
  Rows := ListView_GetItemCount(FGrid);
  Cols := Header_GetItemCount(ListView_GetHeader(FGrid));
  for I := 0 to Rows - 1 do
    for J := 0 to Cols - 1 do
    begin
      CellBuf[0] := #0;
      GetCellTextW(FGrid, I, J, @CellBuf[0], Length(CellBuf));
      Cell := CellBuf;
      if (Cell <> '') and ((Pos(Cell, Selected) > 0) or
        (Pos(Selected, Cell) > 0)) then
      begin
        ListView_SetItemState(FGrid, -1, 0, LVIS_SELECTED or LVIS_FOCUSED);
        ListView_SetItemState(FGrid, I, LVIS_SELECTED or LVIS_FOCUSED,
          LVIS_SELECTED or LVIS_FOCUSED);
        ListView_EnsureVisible(FGrid, I, False);
        SetCurrentCell(I, J);
        Exit;
      end;
    end;
end;

function TJsonViewer.CellData(Row, Column: Integer): TJSONData;
var
  Obj: TJSONObject;
  Index: Integer;
  NameBuf: array[0..4095] of WideChar;
begin
  Result := nil;
  if (Row < 0) or (Row >= Length(FVisibleRowData)) or (Column < 0) then Exit;
  if FCurrent.JSONType = jtArray then
  begin
    Result := FVisibleRowData[Row];
    if Result.JSONType = jtObject then
    begin
      NameBuf[0] := #0;
      GetHeaderText(ListView_GetHeader(FGrid), Column, @NameBuf[0], Length(NameBuf));
      Obj := TJSONObject(Result);
      Index := Obj.IndexOfName(UTF8Encode(UnicodeString(NameBuf)));
      if Index >= 0 then Result := Obj.Items[Index] else Result := nil;
    end
    else if Column <> 0 then
      Result := nil;
  end
  else if FCurrent.JSONType = jtObject then
  begin
    if Column = 1 then Result := FVisibleRowData[Row];
  end
  else if Column = 0 then
    Result := FCurrent;
  if Assigned(Result) and (Result.JSONType in [jtArray, jtObject]) then Result := nil;
end;

procedure TJsonViewer.ToggleEditMode;
begin
  if Assigned(FGroupedRoot) then Exit;
  CloseCellEdit(True);
  if IsWindow(FCellEditor) then Exit;
  FEditMode := not FEditMode;
  UpdateEditStatus;
end;

procedure TJsonViewer.BeginCellEdit(Row, Column: Integer);
var
  R: TRect;
  Data: TJSONData;
  Value: UnicodeString;
begin
  CloseCellEdit(True);
  if not FEditMode then Exit;
  Data := CellData(Row, Column);
  if not Assigned(Data) then
  begin
    MessageBeep(MB_ICONWARNING);
    UpdateEditStatus(Tr(' READ ONLY', ' ТОЛЬКО ЧТЕНИЕ'));
    Exit;
  end;
  FillChar(R, SizeOf(R), 0);
  R.Top := Column;
  R.Left := LVIR_BOUNDS;
  if SendMessageW(FGrid, LVM_GETSUBITEMRECT, Row, LPARAM(@R)) = 0 then Exit;
  if Column = 0 then R.Right := R.Left + ListView_GetColumnWidth(FGrid, 0);
  Value := JsonDisplayValue(Data);
  FEditorRow := Row;
  FEditorColumn := Column;
  FCellEditor := CreateWindowExW(0, 'EDIT', PWideChar(Value),
    WS_CHILD or WS_VISIBLE or ChooseInt(FDark, 0, WS_BORDER) or ES_AUTOHSCROLL,
    R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top,
    FGrid, IDC_CELL_EDITOR, HInstance, nil);
  if FCellEditor = 0 then Exit;
  SendMessageW(FCellEditor, WM_SETFONT, FFont, 1);
  FEditorOldProc := WNDPROC(SetWindowLongPtrW(FCellEditor, GWLP_WNDPROC,
    PtrInt(@EditorWndProc)));
  SendMessageW(FCellEditor, EM_SETSEL, 0, -1);
  SetFocus(FCellEditor);
  UpdateEditStatus(Tr(' EDITING', ' РЕДАКТИРОВАНИЕ'));
end;

procedure TJsonViewer.CloseCellEdit(Accept: Boolean);
var
  Buf: array[0..4095] of WideChar;
  Editor: HWND;
begin
  if FClosingEditor or not IsWindow(FCellEditor) then Exit;
  FClosingEditor := True;
  if Accept then
  begin
    Buf[0] := #0;
    GetWindowTextW(FCellEditor, Buf, Length(Buf));
    if not ApplyCellEdit(FEditorRow, FEditorColumn, Buf) then
    begin
      FClosingEditor := False;
      MessageBeep(MB_ICONWARNING);
      SetFocus(FCellEditor);
      SendMessageW(FCellEditor, EM_SETSEL, 0, -1);
      Exit;
    end;
  end;
  Editor := FCellEditor;
  FCellEditor := 0;
  DestroyWindow(Editor);
  FClosingEditor := False;
  UpdateEditStatus;
end;

function TJsonViewer.ApplyCellEdit(Row, Column: Integer;
  const Value: UnicodeString): Boolean;
var
  Data: TJSONData;
  D: Double;
  FS: TFormatSettings;
  OldValue: UnicodeString;
begin
  Result := False;
  Data := CellData(Row, Column);
  if not Assigned(Data) then Exit;
  OldValue := JsonDisplayValue(Data);
  if Value = OldValue then Exit(True);
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  case Data.JSONType of
    jtString:
      Data.AsString := UTF8Encode(Value);
    jtNumber:
      begin
        if not IsJsonNumberValue(Value) or not TryStrToFloat(Value, D, FS) then
        begin
          UpdateEditStatus(Tr(' INVALID NUMBER', ' НЕКОРРЕКТНОЕ ЧИСЛО'));
          Exit;
        end;
        try
          Data.AsString := UTF8Encode(Value);
        except
          UpdateEditStatus(Tr(' INVALID NUMBER', ' НЕКОРРЕКТНОЕ ЧИСЛО'));
          Exit;
        end;
      end;
    jtBoolean:
      begin
        if (Value <> 'true') and (Value <> 'false') then
        begin
          UpdateEditStatus(Tr(' USE true OR false', ' ВВЕДИ true ИЛИ false'));
          Exit;
        end;
        try
          Data.AsString := UTF8Encode(Value);
        except
          UpdateEditStatus(Tr(' INVALID BOOLEAN', ' НЕКОРРЕКТНОЕ ЛОГИЧЕСКОЕ ЗНАЧЕНИЕ'));
          Exit;
        end;
      end;
    jtNull:
      if Value <> 'null' then
      begin
        UpdateEditStatus(Tr(' USE null', ' ВВЕДИ null'));
        Exit;
      end;
  else
    Exit;
  end;
  if (Row >= 0) and (Row < Length(FVisibleRows)) then
    FAllRows[FVisibleRows[Row], Column] := JsonDisplayValue(Data);
  ApplyFilters;
  InvalidateRect(FTree, nil, True);
  FDirty := True;
  UpdateEditStatus;
  Result := True;
end;

procedure TJsonViewer.UpdateEditStatus(const MessageText: UnicodeString);
var
  S: UnicodeString;
begin
  if MessageText <> '' then S := MessageText
  else if FEditMode and FDirty then S := Tr(' EDIT MODE *', ' РЕДАКТИРОВАНИЕ *')
  else if FEditMode then S := Tr(' EDIT MODE', ' РЕДАКТИРОВАНИЕ')
  else if FDirty then S := Tr(' MODIFIED *', ' ИЗМЕНЕНО *')
  else if Assigned(FGroupedRoot) then S := Tr(' GROUPED (READ ONLY)', ' ГРУППИРОВКА (ТОЛЬКО ЧТЕНИЕ)')
  else S := '';
  SendMessageW(FStatus, SB_SETTEXTW, 5, LPARAM(PWideChar(S)));
end;

function TJsonViewer.SaveChanges: Boolean;
begin
  CloseCellEdit(True);
  if IsWindow(FCellEditor) then Exit(False);
  if not FDirty then
  begin
    UpdateEditStatus(Tr(' NO CHANGES', ' БЕЗ ИЗМЕНЕНИЙ'));
    Exit(True);
  end;
  Result := SaveJsonFile(FFileName, FEncoding, FRoot);
  if Result then
  begin
    FDirty := False;
    UpdateEditStatus(Tr(' SAVED', ' СОХРАНЕНО'));
  end
  else
  begin
    UpdateEditStatus(Tr(' SAVE FAILED', ' ОШИБКА СОХРАНЕНИЯ'));
    MessageBeep(MB_ICONERROR);
  end;
end;

procedure TJsonViewer.ConfirmSaveBeforeClose;
var
  FileLabel, MessageText: UnicodeString;
begin
  CloseCellEdit(True);
  if not FDirty then Exit;
  FileLabel := ExtractFileName(FFileName);
  MessageText := UnicodeFormat(Tr('Save changes to "%s" before closing?',
    'Сохранить изменения в «%s» перед закрытием?'), [FileLabel]);
  if MessageBoxW(FWnd, PWideChar(MessageText), 'jsontab',
    MB_YESNO or MB_ICONWARNING or MB_DEFBUTTON1) = IDYES then
    SaveChanges;
end;

function TJsonViewer.ForwardHostHotKey(Key: WPARAM): Boolean;
var
  Ctrl: Boolean;
  Focus: HWND;
begin
  Result := False;
  Ctrl := (GetKeyState(VK_CONTROL) and $8000) <> 0;
  Focus := GetFocus;
  if Focus = FCellEditor then Exit;
  Result :=
    (Key = VK_ESCAPE) or (Key = VK_F11) or (Key = VK_F3) or
    (Key = VK_F5) or (Key = VK_F7) or (Ctrl and (Key = Ord('F'))) or
    ((Key >= Ord('1')) and (Key <= Ord('8')) and not Ctrl and
      (ReadSettingInt('disable-num-keys', 0) = 0)) or
    (((Key = Ord('N')) or (Key = Ord('P'))) and
      (ReadSettingInt('disable-np-keys', 0) = 0)) or
    ((Key = Ord('Q')) and (ReadSettingInt('exit-by-q', 0) <> 0));
  if not Result then Exit;
  SetFocus(GetParent(FWnd));
  keybd_event(Byte(Key), Byte(MapVirtualKey(Key, MAPVK_VK_TO_VSC)),
    KEYEVENTF_EXTENDEDKEY, 0);
end;

procedure TJsonViewer.SetCurrentCell(Row, Column: Integer);
var
  S: UnicodeString;
begin
  if (Row < 0) or (Row >= ListView_GetItemCount(FGrid)) then Row := -1;
  if (Column < 0) or
    (Column >= Header_GetItemCount(ListView_GetHeader(FGrid))) then Column := -1;
  if (FCurrentRow = Row) and (FCurrentColumn = Column) then Exit;
  FCurrentRow := Row;
  FCurrentColumn := Column;
  if Row >= 0 then ListView_EnsureVisible(FGrid, Row, False);
  InvalidateRect(FGrid, nil, False);
  if (Row >= 0) and (Column >= 0) then
    S := Format(' %d:%d', [Row + 1, Column + 1])
  else
    S := '';
  SendMessageW(FStatus, SB_SETTEXTW, 4, LPARAM(PWideChar(S)));
end;

function TJsonViewer.HandleHotKey(Key: WPARAM): Boolean;
var
  Col, Cols, I, VisibleNo, Direction: Integer;
  Order: array of Integer;
  Ctrl, Shift, IsCopyColumn: Boolean;
begin
  Result := False;
  Ctrl := (GetKeyState(VK_CONTROL) and $8000) <> 0;
  Shift := (GetKeyState(VK_SHIFT) and $8000) <> 0;
  if (Key = Ord('C')) and (GetFocus = FGrid) then
  begin
    IsCopyColumn := (ReadSettingInt('copy-column', 0) <> 0) and
      (ListView_GetSelectedCount(FGrid) > 1);
    if Ctrl or Shift or IsCopyColumn then
    begin
      if Ctrl or IsCopyColumn then CopyColumn
      else CopyRows;
      Exit(True);
    end;
  end;
  Cols := Header_GetItemCount(ListView_GetHeader(FGrid));
  if Ctrl and (Key = Ord('E')) then
  begin
    ToggleEditMode;
    Exit(True);
  end;
  if Ctrl and (Key = Ord('S')) then
  begin
    SaveChanges;
    Exit(True);
  end;
  if Ctrl and (Key = VK_SPACE) then
  begin
    ShowAllColumns;
    Exit(True);
  end;
  if Ctrl and
    (Key >= Ord('0')) and (Key <= Ord('9')) and
    (ReadSettingInt('disable-num-keys', 0) = 0) then
  begin
    if Key = Ord('0') then Col := FCurrentColumn
    else
    begin
      VisibleNo := Key - Ord('1');
      Col := -1;
      SetLength(Order, Cols);
      if Cols > 0 then
        SendMessageW(ListView_GetHeader(FGrid), HDM_GETORDERARRAY, Cols,
          LPARAM(@Order[0]));
      for I := 0 to Cols - 1 do
        if ListView_GetColumnWidth(FGrid, Order[I]) > 0 then
        begin
          if VisibleNo = 0 then begin Col := Order[I]; Break; end;
          Dec(VisibleNo);
        end;
    end;
    if (Col >= 0) and (Col < Cols) and (ListView_GetColumnWidth(FGrid, Col) > 0) then
    begin
      SortGrid(Col);
      Exit(True);
    end;
    Exit(False);
  end;
  if (Key = VK_LEFT) or (Key = VK_RIGHT) then
  begin
    if Cols = 0 then Exit(False);
    Direction := ChooseInt(Key = VK_RIGHT, 1, -1);
    Col := FCurrentColumn;
    repeat
      Col := (Cols + Col + Direction) mod Cols;
    until (ListView_GetColumnWidth(FGrid, Col) > 0) or (Col = FCurrentColumn);
    SetCurrentCell(FCurrentRow, Col);
    Exit(True);
  end;
  Result := ForwardHostHotKey(Key);
end;

procedure TJsonViewer.SortGrid(Column: Integer);
var
  Rows, Cols: Integer;
begin
  Rows := Length(FAllRows);
  Cols := Header_GetItemCount(ListView_GetHeader(FGrid));
  if (Rows < 2) or (Column < 0) or (Column >= Cols) then Exit;
  if FSortColumn = Column then FSortDescending := not FSortDescending
  else begin FSortColumn := Column; FSortDescending := False; end;
  ApplyFilters;
end;

function TJsonViewer.Search(const S: UnicodeString; Flags: Integer): Integer;
var
  I, J, P, StartPos, Rows, Cols, TabNo, RelevantFlags: Integer;
  SelStart, SelEnd: Integer;
  Hay, Needle, TextValue: UnicodeString;
  ResetSearch, Backwards, WasBackwards, DirectionChanged,
    MatchCase, WholeWords: Boolean;

  function IsWordChar(C: WideChar): Boolean;
  begin
    Result := (C = '_') or (C >= '0') and (C <= '9') or
      (C >= 'A') and (C <= 'Z') or (C >= 'a') and (C <= 'z') or
      (Ord(C) >= 128);
  end;

  function ValidWholeWord(const Value: UnicodeString; PosNo: Integer): Boolean;
  var
    AfterPos: Integer;
  begin
    if not WholeWords then Exit(True);
    AfterPos := PosNo + Length(Needle);
    Result := ((PosNo = 1) or not IsWordChar(Value[PosNo - 1])) and
      ((AfterPos > Length(Value)) or not IsWordChar(Value[AfterPos]));
  end;

  function FindForward(const Value: UnicodeString; FromPos: Integer): Integer;
  var
    Tail: UnicodeString;
  begin
    Result := 0;
    if FromPos < 1 then FromPos := 1;
    while FromPos <= Length(Value) do
    begin
      Tail := Copy(Value, FromPos, MaxInt);
      P := Pos(Needle, Tail);
      if P = 0 then Exit;
      Result := FromPos + P - 1;
      if ValidWholeWord(Value, Result) then Exit;
      FromPos := Result + 1;
    end;
  end;

  function FindBackward(const Value: UnicodeString; BeforePos: Integer): Integer;
  var
    Candidate, FromPos: Integer;
  begin
    Result := 0;
    Candidate := 0;
    FromPos := 1;
    if BeforePos > Length(Value) + 1 then BeforePos := Length(Value) + 1;
    while FromPos < BeforePos do
    begin
      P := Pos(Needle, Copy(Value, FromPos, BeforePos - FromPos));
      if P = 0 then Break;
      P := FromPos + P - 1;
      if ValidWholeWord(Value, P) then Candidate := P;
      FromPos := P + 1;
    end;
    Result := Candidate;
  end;

  function SearchValue(const Value: UnicodeString; FromPos: Integer): Integer;
  begin
    if Backwards then Result := FindBackward(Value, FromPos)
    else Result := FindForward(Value, FromPos);
  end;

  procedure SelectGridResult(Row, Column: Integer);
  begin
    ListView_SetItemState(FGrid, -1, 0, LVIS_SELECTED or LVIS_FOCUSED);
    ListView_SetItemState(FGrid, Row, LVIS_SELECTED or LVIS_FOCUSED,
      LVIS_SELECTED or LVIS_FOCUSED);
    ListView_EnsureVisible(FGrid, Row, False);
    SetCurrentCell(Row, Column);
    SetFocus(FGrid);
  end;
begin
  Result := 0;
  if S = '' then Exit;
  TabNo := TabCtrl_GetCurSel(FTab);
  Backwards := (Flags and lcs_backwards) <> 0;
  WasBackwards := (FSearchFlags and lcs_backwards) <> 0;
  DirectionChanged := (FSearchText = S) and (FSearchTab = TabNo) and
    (Backwards <> WasBackwards);
  RelevantFlags := Flags and (lcs_matchcase or lcs_wholewords);
  ResetSearch := (FSearchText <> S) or
    ((FSearchFlags and (lcs_matchcase or lcs_wholewords)) <> RelevantFlags) or
    (FSearchTab <> TabNo) or
    (((Flags and lcs_findfirst) <> 0) and not DirectionChanged);
  MatchCase := (Flags and lcs_matchcase) <> 0;
  WholeWords := (Flags and lcs_wholewords) <> 0;
  Needle := S;
  if not MatchCase then Needle := LowerCase(Needle);
  FSearchText := S;
  FSearchFlags := RelevantFlags or ChooseInt(Backwards, lcs_backwards, 0);
  FSearchTab := TabNo;
  if TabNo = 1 then
  begin
    SetLength(TextValue, GetWindowTextLengthW(FText));
    if TextValue <> '' then GetWindowTextW(FText, PWideChar(TextValue), Length(TextValue) + 1);
    Hay := RichEditPositionText(TextValue);
    if not MatchCase then Hay := LowerCase(Hay);
    SelStart := 0;
    SelEnd := 0;
    SendMessageW(FText, EM_GETSEL, WPARAM(@SelStart), LPARAM(@SelEnd));
    if ResetSearch then
    begin
      if Backwards then StartPos := Length(Hay) + 1 else StartPos := 1;
    end
    else if Backwards then StartPos := SelStart + 1
    else StartPos := SelEnd + 1;
    I := SearchValue(Hay, StartPos);
    if I > 0 then
    begin
      SendMessageW(FText, EM_SETSEL, I - 1, I - 1 + Length(S));
      SendMessageW(FText, EM_SCROLLCARET, 0, 0);
      SetFocus(FText);
    end
    else MessageBeep(0);
    Exit;
  end;
  Rows := ListView_GetItemCount(FGrid);
  Cols := Header_GetItemCount(ListView_GetHeader(FGrid));
  if (Rows = 0) or (Cols = 0) then Exit;
  if ResetSearch then
  begin
    if Backwards then
    begin
      FSearchRow := Rows - 1;
      FSearchColumn := Cols - 1;
      FSearchCellPos := MaxInt;
    end
    else
    begin
      FSearchRow := 0;
      FSearchColumn := 0;
      FSearchCellPos := 1;
    end;
  end;
  if DirectionChanged and not ResetSearch then
  begin
    if Backwards then Dec(FSearchCellPos, Length(S))
    else Inc(FSearchCellPos, Length(S));
  end;
  I := FSearchRow;
  J := FSearchColumn;
  while (I >= 0) and (I < Rows) do
  begin
    while (J >= 0) and (J < Cols) do
    begin
      TextValue := FAllRows[FVisibleRows[I], J];
      Hay := TextValue;
      if not MatchCase then Hay := LowerCase(Hay);
      P := SearchValue(Hay, FSearchCellPos);
      if P > 0 then
      begin
        SelectGridResult(I, J);
        FSearchRow := I;
        FSearchColumn := J;
        if Backwards then FSearchCellPos := P
        else FSearchCellPos := P + Length(S);
        Exit;
      end;
      if Backwards then
      begin
        Dec(J);
        FSearchCellPos := MaxInt;
      end
      else
      begin
        Inc(J);
        FSearchCellPos := 1;
      end;
    end;
    if Backwards then
    begin
      Dec(I);
      J := Cols - 1;
    end
    else
    begin
      Inc(I);
      J := 0;
    end;
  end;
  MessageBeep(0);
end;

function CreateJsonViewer(ParentWin: HWND; const FileName: UnicodeString;
  ShowFlags: Integer; MaxSize: Int64): HWND;
var
  V: TJsonViewer;
begin
  Result := 0;
  try
    V := TJsonViewer.Create(ParentWin, FileName, ShowFlags, MaxSize);
    Result := V.Handle;
  except
    Result := 0;
  end;
end;

procedure CloseJsonViewer(Wnd: HWND);
var
  V: TJsonViewer;
begin
  V := ViewerFromWnd(Wnd);
  if Assigned(V) then
  begin
    V.ConfirmSaveBeforeClose;
    V.Free;
  end;
end;

procedure SetJsonViewerShowFlags(Wnd: HWND; ShowFlags: Integer);
var
  V: TJsonViewer;
begin
  V := ViewerFromWnd(Wnd);
  if Assigned(V) then V.UpdateShowFlags(ShowFlags);
end;

function SearchJsonViewer(Wnd: HWND; const SearchText: UnicodeString;
  SearchFlags: Integer): Integer;
var
  V: TJsonViewer;
begin
  V := ViewerFromWnd(Wnd);
  if Assigned(V) then Result := V.Search(SearchText, SearchFlags) else Result := 0;
end;

end.
