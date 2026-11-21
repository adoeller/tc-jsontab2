unit uSettingsDialog;

{$mode delphi}{$H+}{$codepage utf8}

interface

uses Windows;

function ShowSettingsDialog(Owner: HWND; Dark: Boolean): Boolean;

implementation

uses SysUtils, Types, CommCtrl, uSettings, uLocale, uViewerControls;

function DwmSetWindowAttribute(Wnd: HWND; Attribute: DWORD; Value: Pointer;
  Size: DWORD): HRESULT; stdcall; external 'dwmapi.dll';

type
  TFontEnumCallback = function(var Face: TLogFontW; Metrics: Pointer;
    FontType: DWORD; Param: LPARAM): Integer; stdcall;

function EnumFontFamiliesEx(DC: HDC; var Query: TLogFontW; Callback: TFontEnumCallback;
  Param: LPARAM; Flags: DWORD): Integer; stdcall; external 'gdi32.dll' name 'EnumFontFamiliesExW';

function AddFont(var Face: TLogFontW; Metrics: Pointer; FontType: DWORD;
  Param: LPARAM): Integer; stdcall;
begin
  if (Face.lfFaceName[0] <> '@') and (SendMessageW(HWND(Param), CB_FINDSTRINGEXACT,
    WPARAM(-1), LPARAM(@Face.lfFaceName[0])) = CB_ERR) then
    SendMessageW(HWND(Param), CB_ADDSTRING, 0, LPARAM(@Face.lfFaceName[0]));
  Result := 1;
end;

const
  ThemeID = 101;
  FontID = 102;
  SizeID = 103;
  CaseID = 104;
  LoadID = 105;
  WarningID = 106;
  FolderID = 107;
  EditID = 108;
  ThemeValues: array[TThemeMode] of UnicodeString = ('tc', 'light', 'dark');

type
  TDialogData = record
    Path, Font, LoadText, WarningText: UnicodeString;
    Theme: TThemeMode;
    FontSize: Integer;
    CaseSensitive, Dark: Boolean;
    Back, Input: HBRUSH;
    UIFont: HFONT;
    Tooltips: HWND;
    LoadHint, FolderHint, EditHint: UnicodeString;
  end;
  PDialogData = ^TDialogData;
  PWindowHandle = ^HWND;
  TEmptyDialog = packed record
    Style, ExStyle: DWORD;
    Controls: Word;
    X, Y, W, H: SmallInt;
    Menu, WindowClass, Title: Word;
  end;
  TSettingChanges = array of UnicodeString;

function FindCommander(Wnd: HWND; Ref: LPARAM): BOOL; stdcall;
var ClassName: array[0..63] of WideChar;
    ProcessId: DWORD;
begin
  Result := True;
  GetWindowThreadProcessId(Wnd, @ProcessId);
  if ProcessId <> GetCurrentProcessId then Exit;
  if GetClassNameW(Wnd, ClassName, Length(ClassName)) = 0 then Exit;
  if not SameText(UnicodeString(ClassName), 'TTOTAL_CMD') then Exit;
  PWindowHandle(Ref)^ := Wnd;
  Result := False;
end;

procedure CommanderAction(Dialog: HWND; const Path: UnicodeString; EditFile: Boolean);
var Host: HWND;
    Data: TCopyDataStruct;
    Reply: DWORD_PTR;
    Payload: UTF8String;
    S: UnicodeString;
begin
  Host := 0;
  EnumWindows(@FindCommander, LPARAM(@Host));
  if Host <> 0 then
  begin
    if EditFile then
    begin
      Data.dwData := Ord('E') + 256 * Ord('M');
      S := 'cm_Edit /N="' + Path + '"';
      Payload := #$EF#$BB#$BF + UTF8Encode(S) + #0;
    end
    else
    begin
      Data.dwData := Ord('C') + 256 * Ord('D');
      // The two path slots are separated by CR. S targets the active panel.
      Payload := UTF8Encode(WideChar($FEFF) +
        IncludeTrailingPathDelimiter(ExtractFileDir(Path)) + #13 + WideChar($FEFF)) +
        #0'S'#0;
    end;
    Data.cbData := Length(Payload);
    Data.lpData := PAnsiChar(Payload);
    Reply := 0;
    if (SendMessageTimeoutW(Host, WM_COPYDATA, Dialog, LPARAM(@Data),
      SMTO_ABORTIFHUNG, 2000, @Reply) <> 0) then Exit;
  end;
  MessageBoxW(Dialog, PWideChar(Tr('Total Commander could not complete the command.',
    'Total Commander не смог выполнить команду.')), 'JsonTab', MB_OK or MB_ICONWARNING);
end;

function SaveDialog(Dialog: HWND; Data: PDialogData): Boolean;
var Names, Values: TSettingChanges;
    NewTheme: Integer;
    Size: Integer;
    Count: Int64;
    Font, S, Msg: UnicodeString;
    Sensitive: Boolean;

  procedure Add(const Name, Value: UnicodeString);
  var I: Integer;
  begin
    I := Length(Names);
    SetLength(Names, I + 1);
    SetLength(Values, I + 1);
    Names[I] := Name;
    Values[I] := Value;
  end;

  procedure Invalid(Id: Integer; const MessageText: UnicodeString);
  begin
    MessageBoxW(Dialog, PWideChar(MessageText), 'JsonTab', MB_OK or MB_ICONWARNING);
    SetFocus(GetDlgItem(Dialog, Id));
  end;

begin
  Result := False;
  NewTheme := SendDlgItemMessageW(Dialog, ThemeID, CB_GETCURSEL, 0, 0);
  if (NewTheme >= 0) and (NewTheme <> Ord(Data^.Theme)) then
    Add('theme-mode', ThemeValues[TThemeMode(NewTheme)]);
  Font := Trim(ControlText(GetDlgItem(Dialog, FontID)));
  if (Font = '') or (Length(Font) >= LF_FACESIZE) or (Pos(';', Font) <> 0) or
    (Pos('"', Font) <> 0) or (Pos('''', Font) <> 0) then
  begin
    Invalid(FontID, Tr('Enter a valid font name.', 'Введи корректное название шрифта.'));
    Exit;
  end;
  if Font <> Data^.Font then Add('font', Font);
  Size := StrToIntDef(ControlText(GetDlgItem(Dialog, SizeID)), 0);
  if (Size < 10) or (Size > 48) then
  begin
    Invalid(SizeID, Tr('Text size must be between 10 and 48.',
      'Размер текста должен быть от 10 до 48.'));
    Exit;
  end;
  if Size <> Data^.FontSize then Add('font-size', IntToStr(Size));
  Sensitive := IsDlgButtonChecked(Dialog, CaseID) = BST_CHECKED;
  if Sensitive <> Data^.CaseSensitive then Add('filter-case-sensitive', IntToStr(Ord(Sensitive)));
  S := Trim(ControlText(GetDlgItem(Dialog, LoadID)));
  if S <> Data^.LoadText then
  begin
    if not ParseMiB(S, Count) then
    begin
      Invalid(LoadID, Tr('Enter a positive MiB value equivalent to a whole number of bytes.',
        'Введи положительное значение в МиБ, соответствующее целому числу байтов.'));
      Exit;
    end;
    Add('full-load-max-size', IntToStr(Count));
  end;
  S := Trim(ControlText(GetDlgItem(Dialog, WarningID)));
  if S <> Data^.WarningText then
  begin
    if not ParseMiB(S, Count) then
    begin
      Invalid(WarningID, Tr('Enter a positive MiB value equivalent to a whole number of bytes.',
        'Введи положительное значение в МиБ, соответствующее целому числу байтов.'));
      Exit;
    end;
    Add('large-file-warning-size', IntToStr(Count));
  end;
  try
    SaveSettings(Data^.Path, Names, Values);
    Result := True;
  except
    on E: Exception do
    begin
      Msg := Tr('Could not save the INI file: ', 'Не удалось сохранить INI-файл: ') +
        UnicodeString(E.Message);
      MessageBoxW(Dialog, PWideChar(Msg), 'JsonTab', MB_OK or MB_ICONERROR);
    end;
  end;
end;

procedure PopulateDialog(Wnd: HWND; Data: PDialogData);
var Bounds, ParentBounds: TRect;
    DPI, W, H: Integer;
    EditButton, FolderButton, FontBox, SizeBox, Spinner: HWND;
    FontQuery: TLogFontW;
    Controls: TInitCommonControlsEx;
    DC: HDC;
    DarkCaption: BOOL;

  function Px(N: Integer): Integer;
  begin
    Result := MulDiv(N, DPI, 96);
  end;

  function Add(const Kind, Caption: UnicodeString; Id, X, Y, CW, CH: Integer;
    Style: DWORD = 0; ExStyle: DWORD = 0): HWND;
  begin
    Result := CreateWindowExW(ExStyle, PWideChar(Kind), PWideChar(Caption),
      WS_CHILD or WS_VISIBLE or Style, Px(X), Px(Y), Px(CW), Px(CH), Wnd,
      HMENU(Id), HInstance, nil);
    SendMessageW(Result, WM_SETFONT, Data^.UIFont, 0);
  end;

  procedure LabelAt(const Caption: UnicodeString; X, Y, CW: Integer);
  begin
    Add('STATIC', Caption, -1, X, Y, CW, 20, SS_NOPREFIX);
  end;

  procedure AddSection(const Caption: UnicodeString; Y, H, CaptionWidth: Integer);
  begin
    if Data^.Dark then
    begin
      Add('STATIC', '', -1, 16, Y + 8, 550, H - 8, SS_ETCHEDFRAME);
      LabelAt(Caption, 26, Y, CaptionWidth);
    end
    else Add('BUTTON', Caption, -1, 16, Y, 550, H, BS_GROUPBOX);
  end;

  procedure ThemeOption(const Caption: UnicodeString);
  begin
    SendDlgItemMessageW(Wnd, ThemeID, CB_ADDSTRING, 0, LPARAM(PWideChar(Caption)));
  end;

begin
  DPI := ViewerPixels(Wnd, 96);
  Data^.UIFont := CreateFontW(-Px(15), 0, 0, 0, FW_NORMAL, 0, 0, 0,
    DEFAULT_CHARSET, 0, 0, DEFAULT_QUALITY, 0, 'Segoe UI');
  Bounds := Rect(0, 0, Px(582), Px(414));
  AdjustWindowRectEx(Bounds, GetWindowLongW(Wnd, GWL_STYLE), False,
    GetWindowLongW(Wnd, GWL_EXSTYLE));
  W := Bounds.Right - Bounds.Left;
  H := Bounds.Bottom - Bounds.Top;
  GetWindowRect(GetWindow(Wnd, GW_OWNER), ParentBounds);
  SetWindowPos(Wnd, 0, (ParentBounds.Left + ParentBounds.Right - W) div 2,
    (ParentBounds.Top + ParentBounds.Bottom - H) div 2, W, H, SWP_NOZORDER);
  SetWindowTextW(Wnd, PWideChar(Tr('JsonTab settings', 'Настройки JsonTab')));
  AddSection(Tr('Appearance', 'Внешний вид'), 12, 105, 105);
  LabelAt(Tr('Theme', 'Тема'), 30, 42, 170);
  Add('COMBOBOX', '', ThemeID, 228, 38, 320, 160, WS_TABSTOP or CBS_DROPDOWNLIST);
  ThemeOption(Tr('Follow Total Commander', 'Как в Total Commander'));
  ThemeOption(Tr('Light', 'Светлая'));
  ThemeOption(Tr('Dark', 'Тёмная'));
  SendDlgItemMessageW(Wnd, ThemeID, CB_SETCURSEL, Ord(Data^.Theme), 0);
  LabelAt(Tr('Font', 'Шрифт'), 30, 78, 160);
  FontBox := Add('COMBOBOX', '', FontID, 228, 74, 180, 260,
    WS_TABSTOP or WS_VSCROLL or CBS_DROPDOWN or CBS_AUTOHSCROLL or CBS_SORT);
  FontQuery := Default(TLogFontW);
  FontQuery.lfCharSet := DEFAULT_CHARSET;
  DC := GetDC(Wnd);
  EnumFontFamiliesEx(DC, FontQuery, @AddFont, LPARAM(FontBox), 0);
  ReleaseDC(Wnd, DC);
  SetWindowTextW(FontBox, PWideChar(Data^.Font));
  LabelAt(Tr('Size', 'Размер'), 420, 78, 60);
  SizeBox := Add('EDIT', IntToStr(Data^.FontSize), SizeID, 478, 74, 54, 25,
    WS_TABSTOP or ES_NUMBER, WS_EX_CLIENTEDGE);
  Controls.dwSize := SizeOf(Controls);
  Controls.dwICC := ICC_UPDOWN_CLASS;
  InitCommonControlsEx(Controls);
  Spinner := Add(UPDOWN_CLASSW, '', -1, 531, 74, 17, 25, UDS_SETBUDDYINT or UDS_ARROWKEYS);
  SendMessageW(Spinner, UDM_SETBUDDY, SizeBox, 0);
  SendMessageW(Spinner, UDM_SETRANGE32, 10, 48);
  SendMessageW(Spinner, UDM_SETPOS32, 0, Data^.FontSize);
  AddSection(Tr('Filtering', 'Фильтрация'), 125, 60, 94);
  Add('BUTTON', Tr('Match case', 'Учитывать регистр'), CaseID, 30, 146, 420, 25,
    WS_TABSTOP or BS_AUTOCHECKBOX);
  CheckDlgButton(Wnd, CaseID, Ord(Data^.CaseSensitive));
  AddSection(Tr('Large files', 'Большие файлы'), 193, 116, 120);
  LabelAt(Tr('Stream files larger than (MiB)', 'Потоковый режим для файлов больше, МиБ'), 30, 223, 348);
  Add('EDIT', Data^.LoadText, LoadID, 382, 219, 166, 25, WS_TABSTOP or ES_AUTOHSCROLL, WS_EX_CLIENTEDGE);
  LabelAt(Tr('Warn when opening from (MiB)', 'Предупреждать при открытии от, МиБ'), 30, 256, 348);
  Add('EDIT', Data^.WarningText, WarningID, 382, 252, 166, 25, WS_TABSTOP or ES_AUTOHSCROLL, WS_EX_CLIENTEDGE);
  LabelAt(Data^.LoadHint, 30, 282, 520);
  AddSection(Tr('Active settings file', 'Активный файл настроек'), 317, 56, 200);
  Add('EDIT', Data^.Path, 109, 30, 339, 450, 26,
    WS_TABSTOP or ES_READONLY or ES_AUTOHSCROLL, WS_EX_CLIENTEDGE);
  FolderButton := Add('BUTTON', '📁', FolderID, 490, 339, 26, 26, WS_TABSTOP);
  EditButton := Add('BUTTON', '✎', EditID, 522, 339, 26, 26, WS_TABSTOP);
  EnableWindow(FolderButton, DirectoryExists(ExtractFileDir(Data^.Path)));
  EnableWindow(EditButton, FileExists(Data^.Path));
  Data^.FolderHint := Tr('Open settings folder', 'Открыть папку настроек');
  Data^.EditHint := Tr('Edit INI', 'Редактировать INI');
  Data^.Tooltips := CreateViewerTooltips(Wnd);
  AddViewerTooltip(Data^.Tooltips, FolderButton, PWideChar(Data^.FolderHint));
  AddViewerTooltip(Data^.Tooltips, EditButton, PWideChar(Data^.EditHint));
  Add('BUTTON', Tr('Save', 'Сохранить'), IDOK, 352, 380, 102, 27,
    WS_TABSTOP or BS_DEFPUSHBUTTON);
  Add('BUTTON', Tr('Cancel', 'Отмена'), IDCANCEL, 464, 380, 102, 27, WS_TABSTOP);
  SendMessageW(Wnd, DM_SETDEFID, IDOK, 0);
  if Data^.Dark then
  begin
    DarkCaption := True;
    DwmSetWindowAttribute(Wnd, 20, @DarkCaption, SizeOf(DarkCaption));
    SetViewerControlTheme(GetDlgItem(Wnd, ThemeID), 'DarkMode_CFD');
    SetViewerControlTheme(FontBox, 'DarkMode_CFD');
    SetViewerControlTheme(Spinner, 'DarkMode_Explorer');
    SetViewerControlTheme(GetDlgItem(Wnd, IDOK), 'DarkMode_Explorer');
    SetViewerControlTheme(GetDlgItem(Wnd, IDCANCEL), 'DarkMode_Explorer');
    SetViewerControlTheme(GetDlgItem(Wnd, CaseID), 'DarkMode_Explorer');
    SetViewerControlTheme(FolderButton, 'DarkMode_Explorer');
    SetViewerControlTheme(EditButton, 'DarkMode_Explorer');
  end;
end;

function DialogProc(Wnd: HWND; Msg: UINT; W: WPARAM; L: LPARAM): INT_PTR; stdcall;
var Data: PDialogData;
begin
  Result := 0;
  if Msg = WM_INITDIALOG then
  begin
    SetWindowLongPtrW(Wnd, GWLP_USERDATA, L);
    PopulateDialog(Wnd, PDialogData(L));
    SetFocus(GetDlgItem(Wnd, ThemeID));
    Exit(0);
  end;
  Data := PDialogData(GetWindowLongPtrW(Wnd, GWLP_USERDATA));
  if Data = nil then Exit;
  case Msg of
    WM_CTLCOLORDLG: if Data^.Dark then Exit(Data^.Back);
    WM_CTLCOLORSTATIC, WM_CTLCOLORBTN, WM_CTLCOLOREDIT, WM_CTLCOLORLISTBOX:
      if Data^.Dark then
      begin
        SetTextColor(HDC(W), RGB(235, 235, 235));
        if (Msg = WM_CTLCOLOREDIT) or (Msg = WM_CTLCOLORLISTBOX) then
        begin
          SetBkColor(HDC(W), RGB(52, 52, 52));
          Exit(Data^.Input);
        end;
        SetBkColor(HDC(W), RGB(32, 32, 32));
        Exit(Data^.Back);
      end;
    WM_CLOSE: begin EndDialog(Wnd, IDCANCEL); Exit(1); end;
    WM_COMMAND:
      if HiWord(W) = BN_CLICKED then
      begin
        case LoWord(W) of
          IDOK: if SaveDialog(Wnd, Data) then EndDialog(Wnd, IDOK);
          IDCANCEL: EndDialog(Wnd, IDCANCEL);
          FolderID: CommanderAction(Wnd, Data^.Path, False);
          EditID: CommanderAction(Wnd, Data^.Path, True);
        else Exit;
        end;
        Exit(1);
      end;
  end;
end;

function ShowSettingsDialog(Owner: HWND; Dark: Boolean): Boolean;
var Template: TEmptyDialog;
    Data: TDialogData;
    Threshold: Int64;
begin
  Data := Default(TDialogData);
  Data.Path := IniPath;
  Data.Dark := Dark;
  Data.Theme := ConfiguredThemeMode;
  Data.Font := ReadSetting('font', 'Arial');
  Data.FontSize := ReadSettingInt('font-size', 16);
  if (Data.FontSize < 10) or (Data.FontSize > 48) then Data.FontSize := 16;
  Data.CaseSensitive := ReadSettingInt('filter-case-sensitive', 0) <> 0;
  if not TryStrToInt64(ReadSetting('full-load-max-size', ''), Threshold) or (Threshold <= 0) then
  begin
    Threshold := 5 * 1048576;
    if ReadSetting('max-file-size', 'missing') <> 'missing' then
    begin
      Threshold := 0;
      Data.LoadHint := Tr('Legacy size limit is active. Set a threshold to enable streaming.',
        'Действует старый лимит. Задай порог, чтобы включить потоковый режим.');
    end;
  end;
  if Threshold > 0 then Data.LoadText := FormatMiB(Threshold);
  if not TryStrToInt64(ReadSetting('large-file-warning-size', ''), Threshold) or (Threshold <= 0) then
    Threshold := 1024 * Int64(1048576);
  Data.WarningText := FormatMiB(Threshold);
  if Dark then
  begin
    Data.Back := CreateSolidBrush(RGB(32, 32, 32));
    Data.Input := CreateSolidBrush(RGB(52, 52, 52));
  end;
  Template := Default(TEmptyDialog);
  Template.Style := WS_POPUP or WS_CAPTION or WS_SYSMENU or DS_MODALFRAME;
  Template.ExStyle := WS_EX_CONTROLPARENT;
  Template.W := 240;
  Template.H := 210;
  try
    Result := DialogBoxIndirectParamW(HInstance, PDLGTEMPLATE(@Template),
      GetAncestor(Owner, GA_ROOT), @DialogProc, LPARAM(@Data)) = IDOK;
  finally
    if Data.UIFont <> 0 then DeleteObject(Data.UIFont);
    if Data.Back <> 0 then DeleteObject(Data.Back);
    if Data.Input <> 0 then DeleteObject(Data.Input);
  end;
end;

end.
