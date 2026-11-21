unit uStreamingDb;

{$mode delphi}{$H+}{$codepage utf8}
{$B-}

interface

uses Windows, SysUtils;

type
  TStreamingStatement = class;
  TStreamingDb = class
  private
    FDll: HMODULE;
    FHandle: Pointer;
    FClose: function(Db: Pointer): Integer; cdecl;
    FPrepare: function(Db: Pointer; Sql: PAnsiChar; Bytes: Integer;
      out Stmt: Pointer; Tail: Pointer): Integer; cdecl;
    FError: function(Db: Pointer): PAnsiChar; cdecl;
    FFinalize: function(Stmt: Pointer): Integer; cdecl;
    FReset: function(Stmt: Pointer): Integer; cdecl;
    FStep: function(Stmt: Pointer): Integer; cdecl;
    FBindInt: function(Stmt: Pointer; Param: Integer; Value: Int64): Integer; cdecl;
    FBindText: function(Stmt: Pointer; Param: Integer; Value: PAnsiChar;
      Bytes: Integer; Destroy: Pointer): Integer; cdecl;
    FColInt: function(Stmt: Pointer; Col: Integer): Int64; cdecl;
    FColText: function(Stmt: Pointer; Col: Integer): PAnsiChar; cdecl;
    FColBytes: function(Stmt: Pointer; Col: Integer): Integer; cdecl;
    function Import(const Name: PAnsiChar): Pointer;
    procedure Check(ResultCode: Integer);
  public
    constructor Create(const Path: UnicodeString);
    destructor Destroy; override;
    procedure Exec(const Sql: AnsiString);
    function Prepare(const Sql: AnsiString): TStreamingStatement;
  end;

  TStreamingStatement = class
  private
    FDb: TStreamingDb;
    FStmt: Pointer;
  public
    constructor Create(Db: TStreamingDb; const Sql: AnsiString);
    destructor Destroy; override;
    procedure Reset;
    procedure SetInt(Param: Integer; Value: Int64);
    procedure SetText(Param: Integer; const Value: UTF8String);
    function Step: Boolean;
    function Int(Col: Integer): Int64;
    function Text(Col: Integer): UTF8String;
  end;

implementation

uses uLocale;

const
  SQLITE_ROW = 100;
  SQLITE_DONE = 101;

constructor TStreamingDb.Create(const Path: UnicodeString);
var
  Open: function(Name: PAnsiChar; out Db: Pointer; Flags: Integer;
    Vfs: PAnsiChar): Integer; cdecl;
begin
  inherited Create;
  FDll := LoadLibraryExW('winsqlite3.dll', 0, $00000800); // LOAD_LIBRARY_SEARCH_SYSTEM32
  if FDll = 0 then raise EViewerMessage.CreateText(Tr('Windows SQLite is unavailable', 'SQLite в Windows недоступен'));
  PPointer(@@FClose)^ := Import('sqlite3_close');
  PPointer(@@FError)^ := Import('sqlite3_errmsg');
  PPointer(@@Open)^ := Import('sqlite3_open_v2');
  Check(Open(PAnsiChar(UTF8Encode(Path)), FHandle, $00000006, nil));
  PPointer(@@FPrepare)^ := Import('sqlite3_prepare_v2');
  PPointer(@@FFinalize)^ := Import('sqlite3_finalize');
  PPointer(@@FReset)^ := Import('sqlite3_reset');
  PPointer(@@FStep)^ := Import('sqlite3_step');
  PPointer(@@FBindInt)^ := Import('sqlite3_bind_int64');
  PPointer(@@FBindText)^ := Import('sqlite3_bind_text');
  PPointer(@@FColInt)^ := Import('sqlite3_column_int64');
  PPointer(@@FColText)^ := Import('sqlite3_column_text');
  PPointer(@@FColBytes)^ := Import('sqlite3_column_bytes');
  Exec('PRAGMA journal_mode=OFF');
  Exec('PRAGMA synchronous=OFF');
  Exec('PRAGMA temp_store=FILE');
  Exec('PRAGMA cache_size=-4096');
end;

destructor TStreamingDb.Destroy;
begin
  if FHandle <> nil then FClose(FHandle);
  if FDll <> 0 then FreeLibrary(FDll);
  inherited;
end;

function TStreamingDb.Import(const Name: PAnsiChar): Pointer;
begin
  Result := GetProcAddress(FDll, Name);
  if Result = nil then raise EViewerMessage.CreateText(UnicodeFormat(Tr('Missing SQLite function %s', 'Отсутствует функция SQLite %s'), [Name]));
end;

procedure TStreamingDb.Check(ResultCode: Integer);
begin
  if (ResultCode <> 0) and (ResultCode <> SQLITE_ROW) and (ResultCode <> SQLITE_DONE) then
    raise EViewerMessage.CreateText(Tr('Temporary index: ', 'Временный индекс: ') +
      UTF8Decode(UTF8String(FError(FHandle))));
end;

procedure TStreamingDb.Exec(const Sql: AnsiString);
var S: TStreamingStatement;
begin
  S := Prepare(Sql);
  try
    while S.Step do ;
  finally
    S.Free;
  end;
end;

function TStreamingDb.Prepare(const Sql: AnsiString): TStreamingStatement;
begin
  Result := TStreamingStatement.Create(Self, Sql);
end;

constructor TStreamingStatement.Create(Db: TStreamingDb; const Sql: AnsiString);
begin
  inherited Create;
  FDb := Db;
  FDb.Check(FDb.FPrepare(FDb.FHandle, PAnsiChar(Sql), Length(Sql), FStmt, nil));
end;

destructor TStreamingStatement.Destroy;
begin
  if FStmt <> nil then FDb.FFinalize(FStmt);
  inherited;
end;

procedure TStreamingStatement.Reset;
begin
  FDb.Check(FDb.FReset(FStmt));
end;

procedure TStreamingStatement.SetInt(Param: Integer; Value: Int64);
begin
  FDb.Check(FDb.FBindInt(FStmt, Param, Value));
end;

procedure TStreamingStatement.SetText(Param: Integer; const Value: UTF8String);
const Empty: AnsiChar = #0;
var Data: PAnsiChar;
begin
  if Value = '' then Data := @Empty else Data := PAnsiChar(Value);
  FDb.Check(FDb.FBindText(FStmt, Param, Data, Length(Value), Pointer(PtrInt(-1))));
end;

function TStreamingStatement.Step: Boolean;
var C: Integer;
begin
  C := FDb.FStep(FStmt);
  FDb.Check(C);
  Result := C = SQLITE_ROW;
end;

function TStreamingStatement.Int(Col: Integer): Int64;
begin
  Result := FDb.FColInt(FStmt, Col);
end;

function TStreamingStatement.Text(Col: Integer): UTF8String;
var Data: PAnsiChar;
begin
  Data := FDb.FColText(FStmt, Col);
  SetString(Result, Data, FDb.FColBytes(FStmt, Col));
end;

end.
