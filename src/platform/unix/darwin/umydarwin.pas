{
   Double Commander
   -------------------------------------------------------------------------
   This unit contains specific DARWIN functions.

   Copyright (C) 2016-2023 Alexander Koblov (alexx2000@mail.ru)

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2.1 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; if not, write to the Free Software
   Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301 USA

   Notes:
   1. TDarwinAarch64Statfs is the workaround for the bug of FPC.
      TDarwinAarch64Statfs and the related codes can be removed after FPC 3.3.1
      see also: https://gitlab.com/freepascal.org/fpc/source/-/issues/39873
}

unit uMyDarwin;

{$mode delphi}
{$modeswitch objectivec1}

interface

uses
  Classes, SysUtils, UnixType,
  Cocoa_Extra, MacOSAll, CocoaAll, CocoaUtils, CocoaInt, CocoaConst, CocoaMenus,
  InterfaceBase, Menus, Controls, Forms,
  uDarwinFSWatch;

// Darwin Util Function
function StringToNSString(const S: String): NSString;
function StringToCFStringRef(const S: String): CFStringRef;
function NSArrayToList(const theArray:NSArray): TStringList;
function ListToNSArray(const list:TStrings): NSArray;
function ListToNSUrlArray(const list:TStrings): NSArray;

procedure setMacOSAppearance( mode:Integer );

function getMacOSDefaultTerminal(): String;

procedure FixMacFormatSettings;

function NSGetTempPath: String;

function NSGetFolderPath(Folder: NSSearchPathDirectory): String;

function GetFileDescription(const FileName: String): String;
function MountNetworkDrive(const serverAddress: String): Boolean;

function unmountAndEject(const path: String): Boolean;

// Workarounds for FPC RTL Bug
// copied from ptypes.inc and modified fstypename only
{$if defined(cpuarm) or defined(cpuaarch64) or defined(iphonesim)}
     { structure used on iPhoneOS and available on Mac OS X 10.6 and later }

const MFSTYPENAMELEN = 16;

type TDarwinAarch64Statfs = record
          bsize : cuint32;
          iosize : cint32;
          blocks : cuint64;
          bfree : cuint64;
          bavail : cuint64;
          files : cuint64;
          ffree : cuint64;
          fsid : fsid_t;
          owner : uid_t;
          ftype : cuint32;
          fflags : cuint32;
          fssubtype : cuint32;
          fstypename : array[0..(MFSTYPENAMELEN)-1] of char;
          mountpoint : array[0..(PATH_MAX)-1] of char;
          mntfromname : array[0..(PATH_MAX)-1] of char;
          reserved: array[0..7] of cuint32;
     end;

type TDarwinStatfs = TDarwinAarch64Statfs;

{$else}

type TDarwinStatfs = TStatFs;

{$endif}

// MacOS Simple File Sytem Watcher (only one watchPath)

{ TSimpleDarwinFSWatcher }

TSimpleDarwinFSWatcher = class( TThread )
private
  _monitor: TDarwinFSWatcher;
  _callback: TDarwinFSWatchCallBack;
  _event: TDarwinFSWatchEvent;
protected
  procedure Execute; override;
  procedure handleEvent( event:TDarwinFSWatchEvent );
  procedure doSyncCallback;
public
  procedure stop();
  constructor Create( const path:String; const callback:TDarwinFSWatchCallBack );
  destructor Destroy; override;
end;

// MacOS Service Integration
type TNSServiceProviderCallBack = Procedure( filenames:TStringList ) of object;
type TNSServiceMenuIsReady = Function(): Boolean of object;
type TNSServiceMenuGetFilenames = Function(): TStringList of object;

type TDCCocoaApplication = objcclass(TCocoaApplication)
  function validRequestorForSendType_returnType (sendType: NSString; returnType: NSString): id; override;
  function writeSelectionToPasteboard_types (pboard: NSPasteboard; types: NSArray): ObjCBOOL; message 'writeSelectionToPasteboard:types:';
  procedure observeValueForKeyPath_ofObject_change_context( keyPath: NSString; object_: id; change: NSDictionary; context: pointer); override;
public
  serviceMenuIsReady: TNSServiceMenuIsReady;
  serviceMenuGetFilenames: TNSServiceMenuGetFilenames;
end;

type TNSServiceProvider = objcclass(NSObject)
private
  onOpenWithNewTab: TNSServiceProviderCallBack;
public
  procedure openWithNewTab( pboard:NSPasteboard; userData:NSString; error:NSStringPtr ); message 'openWithNewTab:userData:error:';
end;

type TMacosServiceMenuHelper = class
private
  oldMenuPopupHandler: TNotifyEvent;
  serviceSubMenuCaption: String;
  procedure attachServicesMenu( Sender:TObject);
public
  procedure PopUp( menu:TPopupMenu; caption:String );
end;

procedure InitNSServiceProvider(
  serveCallback: TNSServiceProviderCallBack;
  isReadyFunc: TNSServiceMenuIsReady;
  getFilenamesFunc: TNSServiceMenuGetFilenames );

// MacOS Sharing
procedure showMacOSSharingServiceMenu;

// MacOS Theme
type TNSThemeChangedHandler = Procedure() of object;

procedure InitNSThemeChangedObserver( handler: TNSThemeChangedHandler );

var
  HasMountURL: Boolean = False;
  NSServiceProvider: TNSServiceProvider;
  MacosServiceMenuHelper: TMacosServiceMenuHelper;
  NSThemeChangedHandler: TNSThemeChangedHandler;

implementation

uses
  DynLibs;

{ TSimpleDarwinFSWatcher }

procedure TSimpleDarwinFSWatcher.Execute;
begin
  _monitor.start();
end;

procedure TSimpleDarwinFSWatcher.handleEvent( event:TDarwinFSWatchEvent );
begin
  _event:= event;
  Synchronize( doSyncCallback );
end;

procedure TSimpleDarwinFSWatcher.doSyncCallback;
begin
  _callback( _event );
  _event:= nil;
end;

procedure TSimpleDarwinFSWatcher.stop();
begin
  _monitor.terminate();
end;

constructor TSimpleDarwinFSWatcher.Create(
  const path:String;
  const callback:TDarwinFSWatchCallBack );
begin
  Inherited Create( false );
  _callback:= callback;
  _monitor:= TDarwinFSWatcher.create( handleEvent );
  _monitor.addPath( path );
end;

destructor TSimpleDarwinFSWatcher.Destroy;
begin
  _monitor.terminate;
  FreeAndNil( _monitor );
  inherited;
end;


procedure setMacOSAppearance( mode:Integer );
var
  appearance: NSAppearance;
begin
  if not NSApp.respondsToSelector( ObjCSelector('appearance') ) then
    exit;

  case mode of
    0,1:
      appearance:= nil;
    2:
      appearance:= NSAppearance.appearanceNamed( NSSTR_DARK_NAME );
    3:
      appearance:= NSAppearance.appearanceNamed( NSAppearanceNameAqua );
  end;
  NSApp.setAppearance( appearance );
  NSAppearance.setCurrentAppearance( appearance );
end;

procedure TMacosServiceMenuHelper.attachServicesMenu( Sender:TObject);
var
  servicesItem: TMenuItem;
  subMenu: TCocoaMenu;
begin
  // call the previous OnMenuPopupHandler and restore it
  if Assigned(oldMenuPopupHandler) then oldMenuPopupHandler( Sender );
  OnMenuPopupHandler:= oldMenuPopupHandler;
  oldMenuPopupHandler:= nil;

  // attach the Services Sub Menu by calling NSApplication.setServicesMenu()
  servicesItem:= TPopupMenu(Sender).Items.Find(serviceSubMenuCaption);
  if servicesItem<>nil then
  begin
    subMenu:= TCocoaMenu.alloc.initWithTitle(NSString.string_);
    TCocoaMenuItem(servicesItem.Handle).setSubmenu( subMenu );
    NSApp.setServicesMenu( NSMenu(servicesItem.Handle) );
  end;
end;

procedure TMacosServiceMenuHelper.PopUp( menu:TPopupMenu; caption:String );
begin
  // because the menu item handle will be destroyed in TPopupMenu.PopUp()
  // we can only call NSApplication.setServicesMenu() in OnMenuPopupHandler()
  oldMenuPopupHandler:= OnMenuPopupHandler;
  OnMenuPopupHandler:= attachServicesMenu;
  serviceSubMenuCaption:= caption;
  menu.PopUp();
end;


procedure InitNSServiceProvider(
  serveCallback: TNSServiceProviderCallBack;
  isReadyFunc: TNSServiceMenuIsReady;
  getFilenamesFunc: TNSServiceMenuGetFilenames );
var
  DCApp: TDCCocoaApplication;
  sendTypes: NSArray;
  returnTypes: NSArray;
begin
  DCApp:= TDCCocoaApplication( NSApp );

  // MacOS Service menu incoming setup
  if not Assigned(NSServiceProvider) then
  begin
    NSServiceProvider:= TNSServiceProvider.alloc.init;
    DCApp.setServicesProvider( NSServiceProvider );
    NSUpdateDynamicServices;
  end;
  NSServiceProvider.onOpenWithNewTab:= serveCallback;

  // MacOS Service menu outgoing setup
  sendTypes:= NSArray.arrayWithObject(NSFilenamesPboardType);
  returnTypes:= nil;
  DCApp.serviceMenuIsReady:= isReadyFunc;
  DCApp.serviceMenuGetFilenames:= getFilenamesFunc;
  DCApp.registerServicesMenuSendTypes_returnTypes( sendTypes, returnTypes );
end;

procedure TNSServiceProvider.openWithNewTab( pboard:NSPasteboard; userData:NSString; error:NSStringPtr );
var
  filenameArray{, lClasses}: NSArray;
  filenameList: TStringList;
begin
  filenameArray := pboard.propertyListForType(NSFilenamesPboardType);
  if filenameArray <> nil then
  begin
    if Assigned(onOpenWithNewTab) then
    begin
      filenameList:= NSArrayToList( filenameArray );
      onOpenWithNewTab( filenameList );
      FreeAndNil( filenameList );
    end;
  end;
end;

function TDCCocoaApplication.validRequestorForSendType_returnType (sendType: NSString; returnType: NSString): id;
var
  isSendTypeMatch: ObjcBool;
  isReturnTypeMatch: ObjcBool;
begin
  Result:= nil;
  if not NSFilenamesPboardType.isEqualToString(sendType) then exit;
  if returnType<>nil then exit;
  if self.serviceMenuIsReady() then Result:=self;
end;

function TDCCocoaApplication.writeSelectionToPasteboard_types( pboard: NSPasteboard; types: NSArray): ObjCBOOL;
var
  filenameList: TStringList;
  filenameArray: NSArray;
begin
  Result:= false;
  filenameList:= self.serviceMenuGetFilenames();
  if filenameList=nil then exit;

  filenameArray:= ListToNSArray( filenameList );
  pboard.declareTypes_owner( NSArray.arrayWithObject(NSFileNamesPboardType), nil );
  pboard.setPropertyList_forType( filenameArray, NSFileNamesPboardType );
  Result:= true;

  FreeAndNil( filenameList );
end;

procedure showMacOSSharingServiceMenu;
var
  picker: NSSharingServicePicker;
  filenameArray: NSArray;
  filenameList: TStringList;
  point: TPoint;
  popupNSRect: NSRect;
  control: TWinControl;
begin
  if not TDCCocoaApplication(NSApp).serviceMenuIsReady then
    exit;

  filenameList:= TDCCocoaApplication(NSApp).serviceMenuGetFilenames;
  if filenameList=nil then exit;

  filenameArray:= ListToNSUrlArray( filenameList );
  FreeAndNil( filenameList );

  control:= Screen.ActiveControl;
  point:= control.ScreenToClient( Mouse.CursorPos );
  popupNSRect.origin.x:= point.X;
  popupNSRect.origin.y:= point.Y;
  popupNSRect.size:= NSZeroSize;

  picker:= NSSharingServicePicker.alloc.initWithItems( filenameArray );
  picker.showRelativeToRect_ofView_preferredEdge( popupNSRect, NSView(control.handle) , NSMinYEdge );
  picker.release;
end;

procedure TDCCocoaApplication.observeValueForKeyPath_ofObject_change_context(
  keyPath: NSString; object_: id; change: NSDictionary; context: pointer);
begin
  Inherited observeValueForKeyPath_ofObject_change_context( keyPath, object_, change, context );
  if keyPath.isEqualToString(NSSTR('effectiveAppearance')) then
  begin
    NSAppearance.setCurrentAppearance( self.appearance );
    if Assigned(NSThemeChangedHandler) then NSThemeChangedHandler;
  end;
end;

procedure InitNSThemeChangedObserver( handler: TNSThemeChangedHandler );
begin
  if Assigned(NSThemeChangedHandler) then exit;

  NSApp.addObserver_forKeyPath_options_context(
    NSApp, NSSTR('effectiveAppearance'), 0, nil );

  NSThemeChangedHandler:= handler;
end;



function NSArrayToList(const theArray:NSArray): TStringList;
var
  i: Integer;
  list : TStringList;
begin
  list := TStringList.Create;
  for i := 0 to theArray.Count-1 do
  begin
    list.Add( NSStringToString( theArray.objectAtIndex(i) ) );
  end;
  Result := list;
end;

function ListToNSArray(const list:TStrings): NSArray;
var
  theArray: NSMutableArray;
  item: String;
begin
  theArray := NSMutableArray.arrayWithCapacity( list.Count );
  for item in list do begin
    theArray.addObject( StringToNSString(item) );
  end;
  Result := theArray;
end;

function ListToNSUrlArray(const list:TStrings): NSArray;
var
  theArray: NSMutableArray;
  item: String;
  url: NSUrl;
begin
  theArray:= NSMutableArray.arrayWithCapacity( list.Count );
  for item in list do begin
    url:= NSUrl.fileURLWithPath( StringToNSString(item) );
    theArray.addObject( url );
  end;
  Result:= theArray;
end;

function CFStringToStr(AString: CFStringRef): String;
var
  Str: Pointer;
  StrSize: CFIndex;
  StrRange: CFRange;
begin
  if AString = nil then
  begin
    Result:= EmptyStr;
    Exit;
  end;
  // Try the quick way first
  Str:= CFStringGetCStringPtr(AString, kCFStringEncodingUTF8);
  if Str <> nil then
    Result:= PAnsiChar(Str)
  else begin
    // if that doesn't work this will
    StrRange.location:= 0;
    StrRange.length:= CFStringGetLength(AString);

    CFStringGetBytes(AString, StrRange, kCFStringEncodingUTF8,
                     Ord('?'), False, nil, 0, StrSize{%H-});
    SetLength(Result, StrSize);

    if StrSize > 0 then
    begin
      CFStringGetBytes(AString, StrRange, kCFStringEncodingUTF8,
                       Ord('?'), False, @Result[1], StrSize, StrSize);
    end;
  end;
end;

procedure FixMacFormatSettings;
var
  S: String;
  ALocale: CFLocaleRef;
begin
  ALocale:= CFLocaleCopyCurrent;
  if Assigned(ALocale) then
  begin
    S:= CFStringToStr(CFLocaleGetValue(ALocale, kCFLocaleGroupingSeparator));
    if Length(S) = 0 then
    begin
      DefaultFormatSettings.ThousandSeparator:= #0;
    end;
    CFRelease(ALocale);
  end;
end;

function NSGetTempPath: String;
begin
  Result:= IncludeTrailingBackslash(NSTemporaryDirectory.UTF8String);
end;

function getMacOSDefaultTerminal(): String;
begin
  Result:= NSStringToString( NSWorkspace.sharedWorkspace.fullPathForApplication( NSStr('terminal') ) );
end;

function StringToNSString(const S: String): NSString;
begin
  Result:= NSString(NSString.stringWithUTF8String(PAnsiChar(S)));
end;

function StringToCFStringRef(const S: String): CFStringRef;
begin
  Result:= CFStringCreateWithCString(nil, PAnsiChar(S), kCFStringEncodingUTF8);
end;

function NSGetFolderPath(Folder: NSSearchPathDirectory): String;
var
  Path: NSArray;
begin
  Path:= NSFileManager.defaultManager.URLsForDirectory_inDomains(Folder, NSUserDomainMask);
  if Path.count > 0 then
  begin
    Result:= IncludeTrailingBackslash(NSURL(Path.objectAtIndex(0)).path.UTF8String) + ApplicationName;
  end;
end;

function GetFileDescription(const FileName: String): String;
var
  Error: NSError;
  WS: NSWorkspace;
  FileType: NSString;
  FileNameRef: CFStringRef;
begin
  WS:= NSWorkspace.sharedWorkspace;
  FileNameRef:= StringToCFStringRef(FileName);
  if (FileNameRef = nil) then Exit(EmptyStr);
  FileType:= WS.typeOfFile_error(NSString(FileNameRef), @Error);
  if (FileType = nil) then
    Result:= Error.localizedDescription.UTF8String
  else begin
    Result:= WS.localizedDescriptionForType(FileType).UTF8String;
  end;
  CFRelease(FileNameRef);
end;

function unmountAndEject(const path: String): Boolean;
begin
  Result:= NSWorkspace.sharedWorkspace.unmountAndEjectDeviceAtPath( StringToNSString(path) );
end;


var
  NetFS: TLibHandle = NilHandle;
  CoreServices: TLibHandle = NilHandle;

var
  FSMountServerVolumeSync: function(url: CFURLRef; mountDir: CFURLRef; user: CFStringRef; password: CFStringRef;
    mountedVolumeRefNum: FSVolumeRefNumPtr; flags: OptionBits): OSStatus; stdcall;
  NetFSMountURLSync: function(_url: CFURLRef; _mountpath: CFURLRef; _user: CFStringRef; _passwd: CFStringRef;
    _open_options: CFMutableDictionaryRef; _mount_options: CFMutableDictionaryRef; _mountpoints: CFArrayRefPtr): Int32; cdecl;

function MountNetworkDrive(const serverAddress: String): Boolean;
var
  sharePath: NSURL;
  mountPoints: CFArrayRef = nil;
begin
  sharePath:= NSURL.URLWithString(StringToNSString(serverAddress));
  if Assigned(NetFSMountURLSync) then
    Result:= NetFSMountURLSync(CFURLRef(sharePath), nil, nil, nil, nil, nil, @mountPoints) = 0
  else begin
    Result:= FSMountServerVolumeSync(CFURLRef(sharePath), nil, nil, nil, nil, 0) = noErr;
  end;
end;

procedure Initialize;
begin
  NetFS:= LoadLibrary('/System/Library/Frameworks/NetFS.framework/NetFS');
  if (NetFS <> NilHandle) then
  begin
    @NetFSMountURLSync:= GetProcAddress(NetFS, 'NetFSMountURLSync');
  end;
  CoreServices:= LoadLibrary('/System/Library/Frameworks/CoreServices.framework/CoreServices');
  if (CoreServices <> NilHandle) then
  begin
    @FSMountServerVolumeSync:= GetProcAddress(CoreServices, 'FSMountServerVolumeSync');
  end;
  HasMountURL:= Assigned(NetFSMountURLSync) or Assigned(FSMountServerVolumeSync);
  MacosServiceMenuHelper:= TMacosServiceMenuHelper.Create;
end;

procedure Finalize;
begin
  if (NetFS <> NilHandle) then FreeLibrary(NetFS);
  if (CoreServices <> NilHandle) then FreeLibrary(CoreServices);
  FreeAndNil( MacosServiceMenuHelper );
end;

initialization
  Initialize;

finalization
  Finalize;

end.
