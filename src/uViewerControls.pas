unit uViewerControls;

{$mode delphi}{$H+}{$codepage utf8}

interface

uses Windows, Types, CommCtrl;

const
  ViewerGroupID = 901;
  ViewerFieldID = 902;
  ViewerPatternID = 903;
  ViewerClearID = 904;
  ViewerRefreshID = 905;
  ViewerSettingsID = 906;
  ViewerSummaryID = 907;
  ViewerFilterDelay = 250;

type
  TViewerChrome = record
    GroupBy, Field, Pattern, Clear, FilterSummary, Refresh, Settings, Tooltips: HWND;
    SettingsHint: UnicodeString;
  end;
  TViewerLayout = record
    LeftWidth, RightX, RightWidth, TabWidth, Margin, RowHeight, FilterBottom, StatusTop: Integer;
  end;

procedure CreateViewerChrome(Parent: HWND; var Chrome: TViewerChrome; Font: HFONT);
procedure ThemeViewerChrome(const Chrome: TViewerChrome; Dark: Boolean);
function LayoutViewerChrome(Parent: HWND; const Chrome: TViewerChrome; Split, StatusHeight: Integer;
  FilterVisible: Boolean): TViewerLayout;
function ControlText(Wnd: HWND): UnicodeString;
function CreateViewerTooltips(Parent: HWND): HWND;
procedure AddViewerTooltip(Tips, Control: HWND; Text: PWideChar);
procedure SetViewerControlTheme(Wnd: HWND; Theme: PWideChar);
function ViewerPixels(Wnd: HWND; Pixels: Integer): Integer;
procedure ApplyViewerFontToText(Edit: HWND; Font: HFONT);
procedure DrawViewerButton(const Item: TDrawItemStruct; Dark: Boolean; Back, Fore, Border: COLORREF);
function CreateViewerTree(Parent: HWND; Id: Integer): HWND;
function CreateViewerTabs(Parent: HWND; Id: Integer; Style: DWORD): HWND;
function CreateViewerGrid(Parent: HWND; Id: Integer; Style: DWORD): HWND;
function CreateViewerText(Parent: HWND; Id: Integer): HWND;
procedure ApplyEditBorder(Wnd: HWND; Dark: Boolean);
procedure FillColor(DC: HDC; const R: TRect; Color: COLORREF);
function GetFontHeight(Font: HFONT): Integer;
function DrawGridHeader(Grid: HWND; Hdr: PNMHDR; FillRemainder: Boolean;
  Back, Fore, Border: COLORREF; Font: HFONT; out DrawResult: LRESULT): Boolean;
procedure DrawComboItem(const Item: TDrawItemStruct; Font: HFONT;
  Dark: Boolean; Back, Fore: COLORREF);
function ComboItemText(Combo: HWND; Index: Integer): UnicodeString;
procedure PaintTextScrollbars(Wnd: HWND; DC: HDC;
  TrackColor, ThumbColor, ForeColor: COLORREF);

implementation

uses Math, Messages, SysUtils, RichEdit, uLocale;

function CreateViewerControl(Parent: HWND; Id: Integer; Kind: PWideChar;
  Style: DWORD): HWND;
begin
  Result := CreateWindowExW(0, Kind, nil, WS_CHILD or WS_TABSTOP or Style,
    0, 0, 0, 0, Parent, HMENU(Id), HInstance, nil);
  if Result = 0 then RaiseLastOSError;
end;

function ChangeWindowTheme(Wnd: HWND; SubApp, SubId: PWideChar): HRESULT; stdcall;
  external 'uxtheme.dll' name 'SetWindowTheme';

type
  TGetViewerDpi = function(Wnd: HWND): UINT; stdcall;

var
  GetViewerDpi: TGetViewerDpi;

function ViewerPixels(Wnd: HWND; Pixels: Integer): Integer;
var Dpi: UINT;
begin
  Dpi := 96;
  if Assigned(GetViewerDpi) then Dpi := GetViewerDpi(Wnd);
  if Dpi = 0 then Dpi := 96;
  Result := MulDiv(Pixels, Dpi, 96);
end;

procedure ApplyViewerFontToText(Edit: HWND; Font: HFONT);
var Description: TLogFontW;
    CharFormat: TCharFormat2W;
    DC: HDC;
    Dpi: Integer;
begin
  SendMessageW(Edit, WM_SETFONT, Font, 1);
  if GetObjectW(Font, SizeOf(Description), @Description) = 0 then Exit;
  DC := GetDC(Edit);
  Dpi := GetDeviceCaps(DC, LOGPIXELSY);
  ReleaseDC(Edit, DC);
  if Dpi = 0 then Exit;
  CharFormat := Default(TCharFormat2W);
  CharFormat.cbSize := SizeOf(CharFormat);
  CharFormat.dwMask := CFM_FACE or CFM_SIZE;
  CharFormat.yHeight := MulDiv(Abs(Description.lfHeight), 1440, Dpi);
  Move(Description.lfFaceName, CharFormat.szFaceName, SizeOf(CharFormat.szFaceName));
  SendMessageW(Edit, EM_SETCHARFORMAT, SCF_ALL, LPARAM(@CharFormat));
  SendMessageW(Edit, EM_SETCHARFORMAT, SCF_DEFAULT, LPARAM(@CharFormat));
end;

procedure SetViewerControlTheme(Wnd: HWND; Theme: PWideChar);
begin
  ChangeWindowTheme(Wnd, Theme, nil);
end;

function ControlText(Wnd: HWND): UnicodeString;
var N: Integer;
begin
  N := GetWindowTextLengthW(Wnd);
  SetLength(Result, N + 1);
  SetLength(Result, GetWindowTextW(Wnd, PWideChar(Result), N + 1));
end;

function CreateViewerTooltips(Parent: HWND): HWND;
begin
  Result := CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, nil,
    WS_POPUP or TTS_ALWAYSTIP or TTS_NOPREFIX, 0, 0, 0, 0, Parent, 0, HInstance, nil);
end;

procedure AddViewerTooltip(Tips, Control: HWND; Text: PWideChar);
var Info: TToolInfoW;
begin
  Info := Default(TToolInfoW);
  Info.cbSize := SizeOf(Info);
  Info.uFlags := TTF_IDISHWND or TTF_SUBCLASS;
  Info.hwnd := GetParent(Control);
  Info.uId := Control;
  Info.lpszText := Text;
  SendMessageW(Tips, TTM_ADDTOOLW, 0, LPARAM(@Info));
end;

procedure CreateViewerChrome(Parent: HWND; var Chrome: TViewerChrome; Font: HFONT);
const ComboStyle = WS_VISIBLE or WS_VSCROLL or CBS_DROPDOWNLIST or CBS_OWNERDRAWFIXED or CBS_HASSTRINGS;

  function Add(Id: Integer; const Kind, Caption: UnicodeString; Style: DWORD): HWND;
  begin
    Result := CreateViewerControl(Parent, Id, PWideChar(Kind), WS_VISIBLE or Style or WS_CLIPSIBLINGS);
    SetWindowTextW(Result, PWideChar(Caption));
    SendMessageW(Result, WM_SETFONT, Font, 0);
  end;

begin
  Chrome.GroupBy := Add(ViewerGroupID, 'COMBOBOX', '', ComboStyle);
  Chrome.Field := Add(ViewerFieldID, 'COMBOBOX', '', ComboStyle);
  Chrome.Pattern := Add(ViewerPatternID, 'EDIT', '', ES_AUTOHSCROLL);
  SendMessageW(Chrome.Pattern, EM_SETCUEBANNER, 0,
    LPARAM(PWideChar(Tr('Filter value', 'Значение фильтра'))));
  Chrome.FilterSummary := Add(ViewerSummaryID, 'STATIC', '', SS_LEFTNOWORDWRAP or SS_NOPREFIX);
  SetWindowLongW(Chrome.FilterSummary, GWL_STYLE,
    GetWindowLongW(Chrome.FilterSummary, GWL_STYLE) and not WS_TABSTOP);
  Chrome.Clear := Add(ViewerClearID, 'BUTTON', Tr('Clear all', 'Очистить всё'), BS_OWNERDRAW);
  Chrome.Refresh := Add(ViewerRefreshID, 'BUTTON', Tr('Refresh', 'Обновить'), BS_OWNERDRAW);
  Chrome.Settings := Add(ViewerSettingsID, 'BUTTON', '⚙', BS_OWNERDRAW);
  Chrome.SettingsHint := Tr('Settings', 'Настройки');
  Chrome.Tooltips := CreateViewerTooltips(Parent);
  AddViewerTooltip(Chrome.Tooltips, Chrome.Settings, PWideChar(Chrome.SettingsHint));
end;

procedure ThemeViewerChrome(const Chrome: TViewerChrome; Dark: Boolean);
var Theme: PWideChar;
begin
  Theme := nil;
  if Dark then Theme := 'DarkMode_CFD';
  SetViewerControlTheme(Chrome.GroupBy, Theme);
  SetViewerControlTheme(Chrome.Field, Theme);
  SetViewerControlTheme(Chrome.Pattern, Theme);
  ApplyEditBorder(Chrome.Pattern, Dark);
end;

function LayoutViewerChrome(Parent: HWND; const Chrome: TViewerChrome; Split, StatusHeight: Integer;
  FilterVisible: Boolean): TViewerLayout;
var R: TRect;
    Right, FieldWidth, ClearWidth, EditLeft, RefreshWidth: Integer;

  procedure Place(Wnd: HWND; X, Y, W, H: Integer);
  begin
    SetWindowPos(Wnd, HWND_TOP, X, Y, Max(0, W), Max(0, H), SWP_NOACTIVATE);
  end;

begin
  GetClientRect(Parent, R);
  Result.Margin := ViewerPixels(Parent, 4);
  Result.RowHeight := ViewerPixels(Parent, 30);
  Result.LeftWidth := Min(Max(0, Split), Max(0, R.Right - ViewerPixels(Parent, 160)));
  Result.RightX := Result.LeftWidth + 2 * Result.Margin;
  Right := Max(Result.RightX, R.Right - Result.Margin);
  Result.RightWidth := Right - Result.RightX;
  Result.StatusTop := Max(Result.RowHeight, R.Bottom - StatusHeight);
  Result.FilterBottom := Result.RowHeight + Result.Margin;
  ClearWidth := Min(ViewerPixels(Parent, 105), Result.RightWidth div 3);
  RefreshWidth := Min(ViewerPixels(Parent, 92), Result.RightWidth div 3);
  Result.TabWidth := Min(ViewerPixels(Parent, 135),
    Max(0, Result.RightWidth - RefreshWidth - Result.RowHeight - 2 * Result.Margin));
  Place(Chrome.GroupBy, Result.Margin, Result.Margin, Result.LeftWidth - Result.Margin, ViewerPixels(Parent, 250));
  Place(Chrome.Settings, Right - Result.RowHeight, Result.Margin,
    Result.RowHeight, Result.RowHeight - Result.Margin);
  Place(Chrome.Refresh, Result.RightX + Result.TabWidth + Result.Margin,
    Result.Margin, RefreshWidth, Result.RowHeight - Result.Margin);
  if FilterVisible then
  begin
    FieldWidth := Min(ViewerPixels(Parent, 150), Result.RightWidth div 3);
    EditLeft := Result.RightX + FieldWidth + Result.Margin;
    Place(Chrome.Field, Result.RightX, Result.FilterBottom, FieldWidth, ViewerPixels(Parent, 250));
    Place(Chrome.Pattern, EditLeft, Result.FilterBottom,
      Right - ClearWidth - EditLeft - Result.Margin, Result.RowHeight - Result.Margin);
    Place(Chrome.Clear, Right - ClearWidth, Result.FilterBottom, ClearWidth,
      Result.RowHeight - Result.Margin);
    Inc(Result.FilterBottom, Result.RowHeight);
    Place(Chrome.FilterSummary, Result.RightX, Result.FilterBottom, Result.RightWidth, ViewerPixels(Parent, 20));
    Inc(Result.FilterBottom, ViewerPixels(Parent, 20));
    ShowWindow(Chrome.FilterSummary, SW_SHOW);
    ShowWindow(Chrome.Field, SW_SHOW);
    ShowWindow(Chrome.Pattern, SW_SHOW);
    ShowWindow(Chrome.Clear, SW_SHOW);
  end
  else
  begin
    ShowWindow(Chrome.Field, SW_HIDE);
    ShowWindow(Chrome.Pattern, SW_HIDE);
    ShowWindow(Chrome.Clear, SW_HIDE);
    ShowWindow(Chrome.FilterSummary, SW_HIDE);
  end;
end;

procedure DrawViewerButton(const Item: TDrawItemStruct; Dark: Boolean; Back, Fore, Border: COLORREF);
var R: TRect;
    Text: UnicodeString;
    Frame: HBRUSH;
    IconFont: HFONT;
    Saved: Integer;
begin
  R := Item.rcItem;
  Saved := SaveDC(Item.hDC);
  if Dark then
  begin
    if (Item.itemState and ODS_SELECTED) <> 0 then Back := RGB(78, 78, 78);
    FillColor(Item.hDC, R, Back);
    Frame := CreateSolidBrush(Border);
    FrameRect(Item.hDC, R, Frame);
    DeleteObject(Frame);
  end
  else
  begin
    if (Item.itemState and ODS_SELECTED) <> 0 then
      DrawFrameControl(Item.hDC, R, DFC_BUTTON, DFCS_BUTTONPUSH or DFCS_PUSHED)
    else DrawFrameControl(Item.hDC, R, DFC_BUTTON, DFCS_BUTTONPUSH);
    Fore := GetSysColor(COLOR_BTNTEXT);
  end;
  if (Item.itemState and ODS_DISABLED) <> 0 then Fore := GetSysColor(COLOR_GRAYTEXT);
  SetTextColor(Item.hDC, Fore);
  SetBkMode(Item.hDC, TRANSPARENT);
  SelectObject(Item.hDC, SendMessageW(Item.hwndItem, WM_GETFONT, 0, 0));
  IconFont := 0;
  if Item.CtlID = ViewerSettingsID then
  begin
    IconFont := CreateFontW(-ViewerPixels(Item.hwndItem, 18), 0, 0, 0,
      FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, DEFAULT_QUALITY, 0, 'Segoe UI Symbol');
    if IconFont <> 0 then SelectObject(Item.hDC, IconFont);
  end;
  Text := ControlText(Item.hwndItem);
  DrawTextW(Item.hDC, PWideChar(Text), -1, R, DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
  if (Item.itemState and ODS_FOCUS) <> 0 then
  begin
    InflateRect(R, -3, -3);
    DrawFocusRect(Item.hDC, R);
  end;
  RestoreDC(Item.hDC, Saved);
  if IconFont <> 0 then DeleteObject(IconFont);
end;

function CreateViewerTree(Parent: HWND; Id: Integer): HWND;
begin
  Result := CreateViewerControl(Parent, Id, WC_TREEVIEWW, WS_VISIBLE or
    TVS_HASBUTTONS or TVS_HASLINES or TVS_LINESATROOT or TVS_SHOWSELALWAYS);
end;

function CreateViewerTabs(Parent: HWND; Id: Integer; Style: DWORD): HWND;
var
  Item: TCITEMW;
  Caption: UnicodeString;
begin
  Result := CreateViewerControl(Parent, Id, WC_TABCONTROLW, WS_VISIBLE or Style);
  Item := Default(TCITEMW);
  Item.mask := TCIF_TEXT;
  Caption := Tr('Grid', 'Таблица');
  Item.pszText := PWideChar(Caption);
  SendMessageW(Result, TCM_INSERTITEMW, 0, LPARAM(@Item));
  Caption := Tr('Text', 'Текст');
  Item.pszText := PWideChar(Caption);
  SendMessageW(Result, TCM_INSERTITEMW, 1, LPARAM(@Item));
end;

function CreateViewerGrid(Parent: HWND; Id: Integer; Style: DWORD): HWND;
begin
  Result := CreateViewerControl(Parent, Id, WC_LISTVIEWW, WS_VISIBLE or
    LVS_REPORT or LVS_OWNERDATA or LVS_SHOWSELALWAYS or Style);
end;

function CreateViewerText(Parent: HWND; Id: Integer): HWND;
begin
  Result := CreateViewerControl(Parent, Id, 'RICHEDIT50W',
    ES_MULTILINE or ES_READONLY or WS_VSCROLL or WS_HSCROLL or
    ES_AUTOHSCROLL or ES_AUTOVSCROLL);
end;

procedure ApplyEditBorder(Wnd: HWND; Dark: Boolean);
var
  Style, NewStyle: LONG_PTR;
begin
  if not IsWindow(Wnd) then Exit;
  Style := GetWindowLongPtrW(Wnd, GWL_EXSTYLE);
  if Dark then NewStyle := Style and not WS_EX_CLIENTEDGE
  else NewStyle := Style or WS_EX_CLIENTEDGE;
  if Style <> NewStyle then
  begin
    SetWindowLongPtrW(Wnd, GWL_EXSTYLE, NewStyle);
    SetWindowPos(Wnd, 0, 0, 0, 0, 0,
      SWP_FRAMECHANGED or SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE);
  end;
end;

procedure FillColor(DC: HDC; const R: TRect; Color: COLORREF);
var Brush: HBRUSH;
begin
  Brush := CreateSolidBrush(Color);
  FillRect(DC, R, Brush);
  DeleteObject(Brush);
end;

function GetFontHeight(Font: HFONT): Integer;
var Info: TLogFontW;
begin
  Result := 14;
  if GetObjectW(Font, SizeOf(Info), @Info) <> 0 then Result := Info.lfHeight;
end;

function DrawGridHeader(Grid: HWND; Hdr: PNMHDR; FillRemainder: Boolean;
  Back, Fore, Border: COLORREF; Font: HFONT; out DrawResult: LRESULT): Boolean;
var Draw: PNMCUSTOMDRAW;
    Item: HDITEMW;
    Caption: array[0..4095] of WideChar;
    R, Column: TRect;
    I, Saved: Integer;
    Pen: HPEN;
begin
  Result := False;
  if (Hdr = nil) or (Hdr^.hwndFrom <> ListView_GetHeader(Grid)) or
    (Integer(Hdr^.code) <> NM_CUSTOMDRAW) then Exit;
  Draw := PNMCUSTOMDRAW(Hdr);
  Result := True;
  DrawResult := CDRF_DODEFAULT;
  case Draw^.dwDrawStage of
    CDDS_PREPAINT:
      begin
        DrawResult := CDRF_NOTIFYITEMDRAW;
        if FillRemainder then DrawResult := DrawResult or CDRF_NOTIFYPOSTPAINT;
      end;
    CDDS_POSTPAINT:
      if FillRemainder then
      begin
        GetClientRect(Hdr^.hwndFrom, R);
        for I := 0 to Header_GetItemCount(Hdr^.hwndFrom) - 1 do
          if SendMessageW(Hdr^.hwndFrom, HDM_GETITEMRECT, I, LPARAM(@Column)) <> 0 then
            R.Left := Max(R.Left, Column.Right);
        if R.Left < R.Right then FillColor(Draw^.hdc, R, Back);
      end;
    CDDS_ITEMPREPAINT:
      begin
        FillColor(Draw^.hdc, Draw^.rc, Back);
        Saved := SaveDC(Draw^.hdc);
        Pen := CreatePen(PS_SOLID, 1, Border);
        SelectObject(Draw^.hdc, Pen);
        R := Draw^.rc;
        MoveToEx(Draw^.hdc, R.Right - 1, R.Top, nil);
        LineTo(Draw^.hdc, R.Right - 1, R.Bottom);
        MoveToEx(Draw^.hdc, R.Left, R.Bottom - 1, nil);
        LineTo(Draw^.hdc, R.Right, R.Bottom - 1);
        Item := Default(HDITEMW);
        Caption[0] := #0;
        Item.mask := HDI_TEXT;
        Item.pszText := @Caption[0];
        Item.cchTextMax := Length(Caption);
        SendMessageW(Hdr^.hwndFrom, HDM_GETITEMW, Draw^.dwItemSpec, LPARAM(@Item));
        SelectObject(Draw^.hdc, Font);
        SetBkMode(Draw^.hdc, TRANSPARENT);
        SetTextColor(Draw^.hdc, Fore);
        Inc(R.Left, 6);
        Dec(R.Right, 4);
        DrawTextW(Draw^.hdc, @Caption[0], -1, R,
          DT_LEFT or DT_VCENTER or DT_SINGLELINE or DT_END_ELLIPSIS or DT_NOPREFIX);
        RestoreDC(Draw^.hdc, Saved);
        DeleteObject(Pen);
        DrawResult := CDRF_SKIPDEFAULT;
      end;
  end;
end;

function ComboItemText(Combo: HWND; Index: Integer): UnicodeString;
var N: LRESULT;
begin
  Result := '';
  if Index < 0 then Exit;
  N := SendMessageW(Combo, CB_GETLBTEXTLEN, Index, 0);
  if N <= 0 then Exit;
  SetLength(Result, N);
  SendMessageW(Combo, CB_GETLBTEXT, Index, LPARAM(PWideChar(Result)));
end;

procedure DrawComboItem(const Item: TDrawItemStruct; Font: HFONT;
  Dark: Boolean; Back, Fore: COLORREF);
var R: TRect;
    Caption: UnicodeString;
    Saved: Integer;
begin
  if (Item.itemState and ODS_SELECTED <> 0) and (Item.itemState and ODS_COMBOBOXEDIT = 0) then
  begin
    Back := GetSysColor(COLOR_HIGHLIGHT);
    Fore := GetSysColor(COLOR_HIGHLIGHTTEXT);
  end;
  if Item.itemState and ODS_DISABLED <> 0 then
  begin
    Fore := GetSysColor(COLOR_GRAYTEXT);
    if Dark then Fore := RGB(156,156,156);
  end;
  FillColor(Item.hDC, Item.rcItem, Back);
  if Integer(Item.itemID) < 0 then Exit;
  Caption := ComboItemText(Item.hwndItem, Item.itemID);
  Saved := SaveDC(Item.hDC);
  SelectObject(Item.hDC, Font);
  SetTextColor(Item.hDC, Fore);
  SetBkMode(Item.hDC, TRANSPARENT);
  R := Item.rcItem;
  Inc(R.Left, 4);
  Dec(R.Right, 4);
  DrawTextW(Item.hDC, PWideChar(Caption), Length(Caption), R,
    DT_SINGLELINE or DT_VCENTER or DT_END_ELLIPSIS or DT_NOPREFIX);
  if (Item.itemState and (ODS_FOCUS or ODS_NOFOCUSRECT)) = ODS_FOCUS then
    DrawFocusRect(Item.hDC, Item.rcItem);
  RestoreDC(Item.hDC, Saved);
end;

type
  TViewerScrollbarInfo = record
    cbSize: DWORD;
    rcScrollBar: TRect;
    dxyLineButton, xyThumbTop, xyThumbBottom, reserved: Integer;
    rgstate: array[0..5] of DWORD;
  end;

function ReadScrollbarInfo(Wnd: HWND; ObjectId: LongInt; var Info: TViewerScrollbarInfo): BOOL;
  stdcall; external 'user32.dll' name 'GetScrollBarInfo';

procedure PaintTextScrollbars(Wnd: HWND; DC: HDC;
  TrackColor, ThumbColor, ForeColor: COLORREF);
const
  VerticalId = -5;
  HorizontalId = -6;
  Unavailable = $00000001;
  Hidden = $00018000;
var Bounds, Vertical, Horizontal, Corner: TRect;
    WindowDC: Boolean;

  procedure PaintBar(ObjectId: LongInt; out Bar: TRect);
  var Info: TViewerScrollbarInfo;
      Thumb: TRect;
      IsVertical: Boolean;
      Line, X, Y, Direction, Saved: Integer;
      Pen: HPEN;
      Color: COLORREF;
  begin
    Bar := Default(TRect);
    Info := Default(TViewerScrollbarInfo);
    Info.cbSize := SizeOf(Info);
    if not ReadScrollbarInfo(Wnd, ObjectId, Info) or (Info.rgstate[0] and Hidden <> 0) then Exit;
    Bar := Info.rcScrollBar;
    OffsetRect(Bar, -Bounds.Left, -Bounds.Top);
    FillColor(DC, Bar, TrackColor);
    IsVertical := ObjectId = VerticalId;
    if (Info.rgstate[3] and (Unavailable or Hidden) = 0) and
      (Info.xyThumbBottom > Info.xyThumbTop) then
    begin
      Thumb := Bar;
      if IsVertical then
      begin
        Thumb.Top := Bar.Top + Info.xyThumbTop;
        Thumb.Bottom := Bar.Top + Info.xyThumbBottom;
        InflateRect(Thumb, -3, 0);
      end
      else
      begin
        Thumb.Left := Bar.Left + Info.xyThumbTop;
        Thumb.Right := Bar.Left + Info.xyThumbBottom;
        InflateRect(Thumb, 0, -3);
      end;
      FillColor(DC, Thumb, ThumbColor);
    end;
    Line := Info.dxyLineButton div 2;
    if Line = 0 then Exit;
    Saved := SaveDC(DC);
    for Direction := -1 to 1 do
    begin
      if Direction = 0 then Continue;
      Color := ForeColor;
      if ((Direction = -1) and (Info.rgstate[1] and Unavailable <> 0)) or
        ((Direction = 1) and (Info.rgstate[5] and Unavailable <> 0)) then Color := ThumbColor;
      Pen := CreatePen(PS_SOLID, 1, Color);
      SelectObject(DC, Pen);
      X := (Bar.Left + Bar.Right) div 2;
      Y := (Bar.Top + Bar.Bottom) div 2;
      if IsVertical then
      begin
        if Direction < 0 then Y := Bar.Top + Line else Y := Bar.Bottom - Line;
        MoveToEx(DC, X-3, Y-Direction, nil);
        LineTo(DC, X, Y+Direction*2);
        LineTo(DC, X+4, Y-Direction);
      end
      else
      begin
        if Direction < 0 then X := Bar.Left + Line else X := Bar.Right - Line;
        MoveToEx(DC, X-Direction, Y-3, nil);
        LineTo(DC, X+Direction*2, Y);
        LineTo(DC, X-Direction, Y+4);
      end;
      SelectObject(DC, GetStockObject(BLACK_PEN));
      DeleteObject(Pen);
    end;
    RestoreDC(DC, Saved);
  end;

begin
  if not GetWindowRect(Wnd, Bounds) then Exit;
  WindowDC := DC = 0;
  if WindowDC then DC := GetWindowDC(Wnd);
  if DC = 0 then Exit;
  try
    PaintBar(VerticalId, Vertical);
    PaintBar(HorizontalId, Horizontal);
    if (Vertical.Right > Vertical.Left) and (Horizontal.Bottom > Horizontal.Top) then
    begin
      Corner := Types.Rect(Vertical.Left, Horizontal.Top, Vertical.Right, Horizontal.Bottom);
      FillColor(DC, Corner, TrackColor);
    end;
  finally
    if WindowDC then ReleaseDC(Wnd, DC);
  end;
end;

initialization
  PPointer(@@GetViewerDpi)^ := GetProcAddress(GetModuleHandleW('user32.dll'), 'GetDpiForWindow');

end.
