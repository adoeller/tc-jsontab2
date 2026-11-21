unit uLocale;

{$mode delphi}{$H+}{$codepage utf8}

interface

uses Windows, SysUtils;

type
  EViewerMessage = class(Exception)
  private
    FText: UnicodeString;
  public
    constructor CreateText(const Text: UnicodeString);
  end;

function ViewerErrorText(Error: Exception): UnicodeString;

function Tr(const English, Russian: UnicodeString): UnicodeString; inline;
procedure InitViewerLanguage;

implementation

threadvar
  RussianProfile: Boolean;

procedure InitViewerLanguage;
var
  Profile: array[0..32767] of WideChar;
  Language: array[0..MAX_PATH] of WideChar;
begin
  RussianProfile := False;
  if GetEnvironmentVariableW('COMMANDER_INI', Profile, Length(Profile)) = 0 then Exit;
  GetPrivateProfileStringW('Configuration', 'LanguageINI', '', Language,
    Length(Language), Profile);
  RussianProfile := Pos('wcmd_rus', LowerCase(ExtractFileName(UnicodeString(Language)))) = 1;
end;

function Tr(const English, Russian: UnicodeString): UnicodeString;
begin
  if RussianProfile then Result := Russian else Result := English;
end;

constructor EViewerMessage.CreateText(const Text: UnicodeString);
begin
  inherited Create(Text);
  FText := Text;
end;

function ViewerErrorText(Error: Exception): UnicodeString;
begin
  if Error is EViewerMessage then Result := EViewerMessage(Error).FText
  else Result := UnicodeString(Error.Message);
end;

end.
