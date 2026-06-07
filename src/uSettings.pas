unit uSettings;

{$mode delphi}{$H+}

interface

uses Windows, SysUtils;

procedure SetDefaultIniName(const AName: AnsiString);
function ReadSetting(const Name, Default: UnicodeString): UnicodeString;
function ReadSettingInt(const Name: UnicodeString; Default: Integer): Integer;
procedure WriteSettingInt(const Name: UnicodeString; Value: Integer);
function IniPath: UnicodeString;

implementation

var
  GIniPath: UnicodeString;

function IniPath: UnicodeString;
var
  Buf: array[0..MAX_PATH] of WideChar;
begin
  if GIniPath = '' then
  begin
    GetModuleFileNameW(HInstance, Buf, MAX_PATH);
    GIniPath := ChangeFileExt(Buf, '.ini');
  end;
  Result := GIniPath;
end;

procedure SetDefaultIniName(const AName: AnsiString);
begin
  if GIniPath = '' then
    GIniPath := UnicodeString(AName);
end;

function ReadSetting(const Name, Default: UnicodeString): UnicodeString;
var
  Buf: array[0..1023] of WideChar;
begin
  GetPrivateProfileStringW('jsontab', PWideChar(Name), PWideChar(Default),
    Buf, Length(Buf), PWideChar(IniPath));
  Result := Buf;
end;

function ReadSettingInt(const Name: UnicodeString; Default: Integer): Integer;
begin
  Result := StrToIntDef(ReadSetting(Name, IntToStr(Default)), Default);
end;

procedure WriteSettingInt(const Name: UnicodeString; Value: Integer);
begin
  WritePrivateProfileStringW('jsontab', PWideChar(Name),
    PWideChar(UnicodeString(IntToStr(Value))), PWideChar(IniPath));
end;

end.
