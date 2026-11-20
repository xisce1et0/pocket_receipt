[Setup]
AppName=Карманный чек
AppVersion=1.1.0
DefaultDirName={autopf}\PocketReceipt
DefaultGroupName=Карманный чек
OutputDir=dist
OutputBaseFilename=PocketReceipt_Setup
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\pocket_receipt.exe
Compression=none
SolidCompression=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Карманный чек"; Filename: "{app}\pocket_receipt.exe"
Name: "{autodesktop}\Карманный чек"; Filename: "{app}\pocket_receipt.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\pocket_receipt.exe"; Description: "{cm:LaunchProgram,Карманный чек}"; Flags: nowait postinstall skipifsilent