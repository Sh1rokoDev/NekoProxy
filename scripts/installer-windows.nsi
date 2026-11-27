Unicode true
ManifestDPIAware true
RequestExecutionLevel admin
; 非固实压缩避免在安装目录外暂存解压后的整个数据块。
SetCompressor lzma
SetCompressorDictSize 32
CRCCheck on

!define APP_NAME "NekoProxy"
!ifndef FILE_VERSION
  !error "FILE_VERSION is required. Use scripts/package-windows.ps1."
!endif
!ifndef DISPLAY_VERSION
  !error "DISPLAY_VERSION is required. Use scripts/package-windows.ps1."
!endif
!ifndef PAYLOAD_DIR
  !error "PAYLOAD_DIR is required. Use scripts/package-windows.ps1."
!endif
!define APP_EXE "nekoproxy.exe"
!define ROOT "${__FILEDIR__}\.."
!ifndef OUTPUT_DIR
  !define OUTPUT_DIR "${ROOT}\dist"
!endif
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\NekoProxy"
!define REG_ROOT "Software\NekoProxy"

Name "${APP_NAME}"
OutFile "${OUTPUT_DIR}\NekoProxy-${DISPLAY_VERSION}-windows-x64-setup.exe"
InstallDir "$PROGRAMFILES64\NekoProxy"
InstallDirRegKey HKLM "${REG_ROOT}" "InstallDir"

VIProductVersion "${FILE_VERSION}"
VIAddVersionKey "ProductName" "NekoProxy"
VIAddVersionKey "FileDescription" "NekoProxy installer"
VIAddVersionKey "FileVersion" "${FILE_VERSION}"
VIAddVersionKey "ProductVersion" "${DISPLAY_VERSION}"
VIAddVersionKey "CompanyName" "NekoProxy contributors"
VIAddVersionKey "LegalCopyright" "GPL-3.0-or-later"

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"

!define MUI_ABORTWARNING
!define MUI_ICON "${ROOT}\assets\icons\app_icon.ico"
!define MUI_UNICON "${ROOT}\assets\icons\app_icon.ico"

!insertmacro MUI_PAGE_LICENSE "${PAYLOAD_DIR}\LICENSE"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

LangString LaunchPrompt ${LANG_SIMPCHINESE} "安装完成。现在启动 NekoProxy？"
LangString LaunchPrompt ${LANG_ENGLISH} "Installation complete. Start NekoProxy now?"
LangString StartMenuShortcut ${LANG_SIMPCHINESE} "创建开始菜单快捷方式"
LangString StartMenuShortcut ${LANG_ENGLISH} "Create a Start menu shortcut"
LangString DesktopShortcut ${LANG_SIMPCHINESE} "创建桌面快捷方式"
LangString DesktopShortcut ${LANG_ENGLISH} "Create a desktop shortcut"

Function .onInit
  ; 保留系统级卸载登记，安装文件只释放到 $INSTDIR。
  SetShellVarContext all

  ; 应用内更新先启动安装器，再正常退出并恢复系统代理。
  ${GetParameters} $1
  ClearErrors
  ${GetOptions} $1 "/WAITFORNEKO" $2
  StrCpy $3 0
  ${IfNot} ${Errors}
    StrCpy $3 30
  ${EndIf}

  check_running:
  ExecWait 'cmd /c tasklist /FI "IMAGENAME eq ${APP_EXE}" /FO CSV /NH | findstr /I /C:"${APP_EXE}" >nul' $0
  ${If} $0 == "0"
    ${If} $3 > 0
      IntOp $3 $3 - 1
      Sleep 1000
      Goto check_running
    ${EndIf}
    MessageBox MB_OK|MB_ICONSTOP "NekoProxy 正在运行。请先从托盘退出程序，再重新运行安装程序。"
    Abort
  ${EndIf}
FunctionEnd

Function .onInstSuccess
  IfSilent done
  MessageBox MB_YESNO|MB_ICONQUESTION "$(LaunchPrompt)" IDNO done
  Exec '"$INSTDIR\${APP_EXE}"'
  done:
FunctionEnd

Section "NekoProxy（必需）" SecMain
  SectionIn RO
  ExecWait 'cmd /c taskkill /IM nekoproxy-worker.exe /F >nul 2>&1' $0

  CreateDirectory "$INSTDIR\userdata"
  ; 数据目录含明文订阅配置，只放行 SYSTEM 与 Administrators。
  ClearErrors
  ExecWait '"$SYSDIR\icacls.exe" "$INSTDIR\userdata" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F"' $0
  ${If} ${Errors}
  ${OrIf} $0 != 0
    MessageBox MB_OK|MB_ICONSTOP "无法设置 NekoProxy 数据目录的权限。"
    Abort
  ${EndIf}

  SetOutPath "$INSTDIR"
  File /r "${PAYLOAD_DIR}\*.*"
  WriteUninstaller "$INSTDIR\uninstall.exe"

  WriteRegStr HKLM "${REG_ROOT}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayVersion" "${DISPLAY_VERSION}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "Publisher" "NekoProxy contributors"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\${APP_EXE}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTALL_KEY}" "NoRepair" 1
SectionEnd

Section "$(StartMenuShortcut)" SecStartMenu
  CreateDirectory "$SMPROGRAMS\NekoProxy"
  CreateShortCut "$SMPROGRAMS\NekoProxy\NekoProxy.lnk" "$INSTDIR\${APP_EXE}"
SectionEnd

Section /o "$(DesktopShortcut)" SecDesktop
  CreateShortCut "$DESKTOP\NekoProxy.lnk" "$INSTDIR\${APP_EXE}"
SectionEnd

Function un.onInit
  ; 安装程序与卸载程序都以管理员权限运行，直接使用全局快捷方式与 HKLM。
  SetShellVarContext all
FunctionEnd

Section "Uninstall"
  SetShellVarContext all
  ExecWait 'cmd /c taskkill /IM ${APP_EXE} /F >nul 2>&1' $0
  ExecWait 'cmd /c taskkill /IM nekoproxy-worker.exe /F >nul 2>&1' $0
  Delete "$SMPROGRAMS\NekoProxy\NekoProxy.lnk"
  Delete "$SMPROGRAMS\NekoProxy\卸载 NekoProxy.lnk"
  RMDir "$SMPROGRAMS\NekoProxy"
  Delete "$DESKTOP\NekoProxy.lnk"
  ${If} $INSTDIR != ""
    ; 用户数据保存在安装目录内，卸载时一并删除。
    RMDir /r "$INSTDIR"
  ${EndIf}
  DeleteRegKey HKLM "${UNINSTALL_KEY}"
  DeleteRegKey HKLM "${REG_ROOT}"
  ; 清理旧版用户级安装可能留下的注册表项。
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  DeleteRegKey HKCU "${REG_ROOT}"
SectionEnd
