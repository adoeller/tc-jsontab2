unit plugin_main;

{$mode delphi}{$H+}

interface

uses Windows, SysUtils, listplug;

function ListLoad(ParentWin: HWND; FileToLoad: PAnsiChar; ShowFlags: Integer): HWND; stdcall;
function ListLoadW(ParentWin: HWND; FileToLoad: PWideChar; ShowFlags: Integer): HWND; stdcall;
procedure ListCloseWindow(ListWin: HWND); stdcall;
procedure ListGetDetectString(DetectString: PAnsiChar; MaxLen: Integer); stdcall;
procedure ListSetDefaultParams(Dps: PListDefaultParamStruct); stdcall;
function ListSendCommand(ListWin: HWND; Command, Parameter: Integer): Integer; stdcall;
function ListSearchText(ListWin: HWND; SearchString: PAnsiChar; SearchParameter: Integer): Integer; stdcall;
function ListSearchTextW(ListWin: HWND; SearchString: PWideChar; SearchParameter: Integer): Integer; stdcall;

implementation

uses uSettings, uViewer, uLargeViewer, uLocale;

function ListSendCommand(ListWin: HWND; Command, Parameter: Integer): Integer; stdcall;
begin
  Result := 1;  // LISTPLUGIN_ERROR
  if Command = lc_newparams then
  begin
    if IsLargeViewer(ListWin) then SetLargeShowFlags(ListWin, Parameter)
    else SetJsonViewerShowFlags(ListWin, Parameter);
    Result := 0;  // LISTPLUGIN_OK
  end;
end;

function ListLoadW(ParentWin: HWND; FileToLoad: PWideChar; ShowFlags: Integer): HWND; stdcall;
var St: WIN32_FILE_ATTRIBUTE_DATA;
    Size, Threshold: Int64;
    Streaming: Boolean;
begin
  Result := 0;
  if FileToLoad = nil then Exit;
  InitViewerLanguage;
  Streaming := LargeFileThreshold(Threshold);
  if Streaming and GetFileAttributesExW(FileToLoad, GetFileExInfoStandard, @St) then
  begin
    Size := (Int64(St.nFileSizeHigh) shl 32) or St.nFileSizeLow;
    if Size > Threshold then Exit(CreateLargeViewer(ParentWin, FileToLoad, Size, ShowFlags));
  end;
  Result := CreateJsonViewer(ParentWin, FileToLoad, ShowFlags, Threshold);
end;

function ListLoad(ParentWin: HWND; FileToLoad: PAnsiChar; ShowFlags: Integer): HWND; stdcall;
begin
  Result := ListLoadW(ParentWin, PWideChar(UnicodeString(AnsiString(FileToLoad))), ShowFlags);
end;

procedure ListCloseWindow(ListWin: HWND); stdcall;
begin
  if IsLargeViewer(ListWin) then CloseLargeViewer(ListWin) else CloseJsonViewer(ListWin);
end;

procedure ListGetDetectString(DetectString: PAnsiChar; MaxLen: Integer); stdcall;
var
  S: AnsiString;
begin
  S := UTF8Encode(ReadSetting('detect-string',
    'MULTIMEDIA & (ext="JSON" | ext="JSONL")'));
  StrLCopy(DetectString, PAnsiChar(S), MaxLen - 1);
end;

procedure ListSetDefaultParams(Dps: PListDefaultParamStruct); stdcall;
begin
  if Assigned(Dps) then
    SetDefaultIniName(AnsiString(PAnsiChar(@Dps^.DefaultIniName[0])));
end;

function ListSearchTextW(ListWin: HWND; SearchString: PWideChar; SearchParameter: Integer): Integer; stdcall;
begin
  if IsLargeViewer(ListWin) then Result := SearchLargeViewer(ListWin, SearchString, SearchParameter)
  else Result := SearchJsonViewer(ListWin, SearchString, SearchParameter);
end;

function ListSearchText(ListWin: HWND; SearchString: PAnsiChar; SearchParameter: Integer): Integer; stdcall;
begin
  Result := ListSearchTextW(ListWin,
    PWideChar(UnicodeString(AnsiString(SearchString))), SearchParameter);
end;

end.
