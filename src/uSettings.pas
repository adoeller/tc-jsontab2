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
  GDefaultIniPath: UnicodeString;

function StripInlineComment(const Value: UnicodeString): UnicodeString;
var
  I: Integer;
  Quote: WideChar;
begin
  Quote := #0;
  I := 1;
  while I <= Length(Value) do
  begin
    if (Value[I] = '"') or (Value[I] = '''') then
    begin
      if Quote = #0 then Quote := Value[I]
      else if Quote = Value[I] then Quote := #0;
    end
    else if (Value[I] = ';') and (Quote = #0) and (I > 1) and
      ((Value[I - 1] <= ' ') or
      ((I < Length(Value)) and (Value[I + 1] <= ' '))) then
      Exit(TrimRight(Copy(Value, 1, I - 1)));
    Inc(I);
  end;
  Result := TrimRight(Value);
end;

function IniPath: UnicodeString;
var
  Buf: array[0..MAX_PATH] of WideChar;
  LocalIniPath: UnicodeString;
begin
  GetModuleFileNameW(HInstance, Buf, MAX_PATH);
  LocalIniPath := ChangeFileExt(Buf, '.ini');
  if FileExists(LocalIniPath) or (GDefaultIniPath = '') then
    Result := LocalIniPath
  else
    Result := GDefaultIniPath;
end;

procedure SetDefaultIniName(const AName: AnsiString);
begin
  if GDefaultIniPath = '' then
    GDefaultIniPath := UnicodeString(AName);
end;

function ReadSetting(const Name, Default: UnicodeString): UnicodeString;
var
  Buf: array[0..1023] of WideChar;
begin
  GetPrivateProfileStringW('jsontab', PWideChar(Name), PWideChar(Default),
    Buf, Length(Buf), PWideChar(IniPath));
  Result := StripInlineComment(Buf);
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
