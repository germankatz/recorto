;==============================================================================
;  Recorto - captura una región de la pantalla y la guarda como PDF / PNG / JPG
;
;  Requisitos:
;    - AutoHotkey v1.1.33 o superior, Unicode (32 o 64 bits). NO funciona con v2.
;    - Gdip_All.ahk en la misma carpeta (se incluye al final del archivo).
;    - magick.exe (ImageMagick portable) es OPCIONAL. Si está, se usa para
;      convertir a PDF y JPG. Si no está, Recorto lo resuelve solo: JPEG con el
;      codificador de GDI+ y PDF con un generador propio (ver WritePdfFromPng).
;      En Windows 7 conviene NO ponerlo: los binarios actuales de ImageMagick
;      importan api-ms-win-core-synch-l1-2-0.dll, que ahí no existe.
;
;  Portable de verdad: no escribe en el registro, no instala nada, no usa .NET
;  ni nada que Windows 7 SP1 no traiga de fábrica. Toda la configuración vive
;  en config.ini, al lado del ejecutable.
;
;  Licencia MIT.
;==============================================================================

#NoEnv
#Persistent
#KeyHistory 0

; --- Instancia única -------------------------------------------------------
; OJO: NO se usa "#SingleInstance Ignore". Con esa directiva AutoHotkey mata a
; la segunda instancia ANTES de ejecutar la primera línea del script, así que
; la segunda nunca llegaría a avisarle a la primera que abra el recorte, que es
; justo lo que hace falta para que el ícono anclado a la barra de tareas sirva
; de botón. Por eso se pone "Off" y el comportamiento de "Ignore" se replica a
; mano acá abajo: un mutex con nombre decide quién es la instancia principal, y
; una ventana-buzón oculta recibe el aviso de las siguientes.
#SingleInstance Off

ListLines Off
SetBatchLines, -1
SendMode Input
SetWorkingDir %A_ScriptDir%
CoordMode, Mouse, Screen

; --- Directivas para Ahk2Exe (se ignoran al correr como .ahk) --------------
;@Ahk2Exe-SetMainIcon      recorto.ico
;@Ahk2Exe-SetName          Recorto
;@Ahk2Exe-SetDescription   Recorto - recorte de pantalla a PDF
;@Ahk2Exe-SetVersion       1.0.0.0
;@Ahk2Exe-SetProductName   Recorto
;@Ahk2Exe-SetCopyright     MIT License
;@Ahk2Exe-SetOrigFilename  recorto.exe


;==============================================================================
;  ESTADO GLOBAL
;  Declarados con "global" fuera de toda función: son super-globales y se ven
;  desde cualquier función sin volver a declararlos.
;==============================================================================
global APP_NAME    := "Recorto"
global APP_VERSION := "1.0.0"
global IPC_TITLE   := "Recorto_IPC_Mailbox_7A31"
global MUTEX_NAME  := "Local\Recorto_SingleInstance_7A31"

; Configuración (config.ini)
global g_IniFile       := ""
global g_Hotkey        := "F8"
global g_DefaultFormat := "pdf"
global g_JpgQuality    := 92
global g_PdfDensity    := 96
global g_InitialDir    := ""
global g_Opacity       := 45
global g_PdfEngine     := "auto"   ; auto | magick | interno

; Infraestructura
global g_pToken  := 0        ; token de GDI+
global g_hIPC    := 0        ; hwnd de la ventana-buzón
global g_MsgSnip := 0        ; id del mensaje registrado
global g_Busy    := 0        ; hay un guardado en curso

; Escritorio virtual (puede empezar en coordenadas negativas)
global g_VX := 0, g_VY := 0, g_VW := 0, g_VH := 0

; Overlay
global g_Overlaying := 0     ; lo usan las #If de los hotkeys del overlay
global g_hOverlay   := 0
global g_Dragging   := 0
global g_x1 := 0, g_y1 := 0, g_x2 := 0, g_y2 := 0
global g_LastMX := -999999, g_LastMY := -999999
global g_ForceDraw  := 0

; Recursos GDI / GDI+ del overlay. TODOS se liberan en DestroyOverlay().
global g_pBmpScreen := 0                                ; captura original
global g_hdcDark := 0, g_hbmDark := 0, g_obmDark := 0   ; captura oscurecida
global g_hdcBuf  := 0, g_hbmBuf  := 0, g_obmBuf  := 0   ; buffer de composición


;==============================================================================
;  ARRANQUE
;==============================================================================

; 1) DPI awareness. Va antes de medir la pantalla o crear ventanas: si el
;    proceso no es DPI-aware y el usuario tiene el escalado en 125 o 150%,
;    Windows le miente sobre el tamaño del escritorio y la captura sale
;    borrosa y con las coordenadas corridas.
MakeProcessDpiAware()

; 2) Argumentos. Se leen antes que nada porque /tray también cambia lo que hace
;    una segunda instancia (avisar o no avisar).
snipOnStart := true
for idx, arg in A_Args
{
    if (arg = "/tray" || arg = "-tray" || arg = "--tray")
        snipOnStart := false
    else if (arg = "/snip" || arg = "-snip" || arg = "--snip")
        snipOnStart := true
}

; 3) Instancia única + IPC (ver la nota sobre #SingleInstance más arriba).
g_MsgSnip := DllCall("RegisterWindowMessage", "Str", "RecortoSnipRequest", "UInt")
hMutex := DllCall("CreateMutexW", "Ptr", 0, "Int", 1, "WStr", MUTEX_NAME, "Ptr")
if (A_LastError = 183)   ; ERROR_ALREADY_EXISTS: ya hay una instancia viva
{
    DetectHiddenWindows, On
    SetTitleMatchMode, 3
    hPrev := 0
    ; Reintentos cortos: la primera instancia puede estar todavía arrancando.
    Loop, 40
    {
        hPrev := WinExist(IPC_TITLE " ahk_class AutoHotkeyGUI")
        if (hPrev)
            break
        Sleep, 75
    }
    if (hPrev)
    {
        ; Le pedimos a la instancia residente que abra el modo recorte y nos
        ; vamos. Esto es lo que hace que el ícono anclado a la barra de tareas
        ; funcione como un botón de "recortar ahora" en vez de abrir una
        ; segunda copia del programa. Con /tray no se avisa nada: sólo se
        ; comprueba que ya hay una instancia y se sale.
        if (snipOnStart)
            PostMessage, %g_MsgSnip%, 0, 0, , ahk_id %hPrev%
        ExitApp
    }
    ; El mutex existe pero nunca apareció el buzón: la instancia previa se está
    ; cerrando. Seguimos nosotros como instancia principal.
}

; 4) GDI+
g_pToken := Gdip_Startup()
if (!g_pToken)
{
    MsgBox, 16, %APP_NAME%, No se pudo iniciar GDI+ (gdiplus.dll).`n`nRecorto no puede funcionar sin GDI+.
    ExitApp
}
OnExit, App_Exit

; 5) Configuración
LoadConfig()

; 6) Ventana-buzón oculta: es la que recibe el mensaje de las segundas
;    instancias. Nunca se muestra.
Gui, IPC:New, -Caption +ToolWindow +HwndhIPCTmp
Gui, IPC:Show, Hide w1 h1, %IPC_TITLE%
g_hIPC := hIPCTmp
if (g_MsgSnip)
    OnMessage(g_MsgSnip, "OnSnipRequest")
OnMessage(0x0020, "OnSetCursor")   ; WM_SETCURSOR: cursor de cruz en el overlay

; 7) Hotkey global (antes del menú, porque si el hotkey del ini es inválido
;    ApplyHotkey lo reemplaza y el menú tiene que mostrar el bueno).
ApplyHotkey()

; 8) Bandeja
BuildTrayMenu()

; 9) Al ejecutar el .exe sin instancia previa, además de quedar residente se
;    abre el recorte de una: es lo que se espera al hacerle click al ícono
;    anclado. Con /tray arranca callado, útil para la carpeta de Inicio.
if (snipOnStart)
    SetTimer, DeferredSnip, -250
return   ; ---- fin de la sección de auto-ejecución ----


;==============================================================================
;  HOTKEYS
;==============================================================================

HK_Snip:
    StartSnip(0)
return

DeferredSnip:
    StartSnip(0)
return

; Hotkeys que sólo existen mientras el overlay está arriba. Se apoyan en la
; super-global g_Overlaying, así funcionan sin necesidad de que la ventana del
; overlay tenga el foco del teclado.
#If (g_Overlaying)

LButton::
    MouseGetPos, mdx, mdy
    g_x1 := mdx, g_y1 := mdy
    g_x2 := mdx, g_y2 := mdy
    g_Dragging := 1
    g_ForceDraw := 1
return

LButton Up::
    FinishSnip()
return

RButton::
Escape::
    CancelSnip()
return

#If   ; ---- fin del contexto del overlay ----


;==============================================================================
;  CONFIGURACIÓN
;==============================================================================

; Lee config.ini; si no existe lo crea con los valores por defecto.
LoadConfig()
{
    g_IniFile := A_ScriptDir "\config.ini"
    if (!FileExist(g_IniFile))
        WriteDefaultConfig()

    g_Hotkey        := IniGet("General", "Hotkey",         "F8")
    g_DefaultFormat := IniGet("General", "DefaultFormat",  "pdf")
    g_JpgQuality    := IniGet("General", "JpgQuality",     92)
    g_PdfDensity    := IniGet("General", "PdfDensity",     96)
    g_InitialDir    := IniGet("General", "InitialDir",     "")
    g_Opacity       := IniGet("General", "OverlayOpacity", 45)
    g_PdfEngine     := IniGet("General", "PdfEngine",      "auto")

    ; --- validación: un ini roto no tiene que romper la app ---
    StringLower, g_DefaultFormat, g_DefaultFormat
    if (g_DefaultFormat != "pdf" && g_DefaultFormat != "png" && g_DefaultFormat != "jpg")
        g_DefaultFormat := "pdf"

    StringLower, g_PdfEngine, g_PdfEngine
    if (g_PdfEngine != "auto" && g_PdfEngine != "magick" && g_PdfEngine != "interno")
        g_PdfEngine := "auto"

    g_JpgQuality := Clamp(Round(g_JpgQuality), 1, 100)
    g_PdfDensity := Clamp(Round(g_PdfDensity), 10, 1200)
    g_Opacity    := Clamp(Round(g_Opacity), 0, 95)

    if (g_Hotkey = "")
        g_Hotkey := "F8"
    if (g_InitialDir = "" || !InStr(FileExist(g_InitialDir), "D"))
        g_InitialDir := A_MyDocuments
}

; IniRead devuelve el default sólo si falta la clave; si la clave existe pero
; está vacía devuelve "". Este wrapper unifica los dos casos.
IniGet(section, key, default)
{
    IniRead, v, % g_IniFile, % section, % key, % "__RECORTO_SIN_VALOR__"
    if (v = "__RECORTO_SIN_VALOR__" || v = "ERROR" || v = "")
        return default
    return v
}

; El ini se escribe en UTF-16 LE con BOM a propósito: además de ANSI, es la
; única codificación que las APIs de ini de Windows entienden de forma nativa,
; y así se pueden guardar rutas con acentos sin romper nada. Los saltos de
; línea van con CRLF porque el Notepad de Windows 7 no muestra los LF sueltos.
WriteDefaultConfig()
{
    nl := "`r`n"
    txt := "; ============================================================" nl
         . "; Recorto - configuración" nl
         . "; Guardá este archivo en UTF-16 LE o ANSI, y reiniciá Recorto" nl
         . "; para que los cambios tomen efecto." nl
         . "; ============================================================" nl
         . nl
         . "[General]" nl
         . nl
         . "; Hotkey global que dispara el recorte." nl
         . "; Sintaxis de AutoHotkey:  ^ = Ctrl   ! = Alt   + = Shift   # = Win" nl
         . "; Ejemplos:  F8    ^!s    #PrintScreen    ^+F12" nl
         . "Hotkey=F8" nl
         . nl
         . "; Formato preseleccionado en el diálogo de guardado: pdf | png | jpg" nl
         . "DefaultFormat=pdf" nl
         . nl
         . "; Calidad JPG (1-100). Sólo aplica al guardar como .jpg" nl
         . "JpgQuality=92" nl
         . nl
         . "; Densidad del PDF en DPI. Con 96, un recorte de 960 px de ancho" nl
         . "; ocupa 10 pulgadas de página: el tamaño físico real que tenía en" nl
         . "; pantalla. Subilo a 150 o 300 si querés una hoja más chica." nl
         . "PdfDensity=96" nl
         . nl
         . "; Carpeta que abre el diálogo de guardado. Recorto la actualiza sola" nl
         . "; con la última carpeta usada." nl
         . "InitialDir=" nl
         . nl
         . "; Oscurecimiento del overlay, 0-95 (%). 45 = negro al 45%." nl
         . "OverlayOpacity=45" nl
         . nl
         . "; Quién genera el PDF y el JPG:" nl
         . ";   auto    = usa magick.exe si está en la carpeta; si no está o si" nl
         . ";             falla, Recorto lo resuelve solo (recomendado)" nl
         . ";   magick  = exige magick.exe y no usa el generador interno" nl
         . ";   interno = ignora magick.exe siempre" nl
         . "; OJO: los binarios actuales de ImageMagick NO arrancan en Windows 7." nl
         . "; Ahí dejá esto en auto o interno." nl
         . "PdfEngine=auto" nl
         . nl
         . "; 1 = declarar el proceso DPI-aware (recomendado). Ponelo en 0 sólo" nl
         . "; si con escalado de pantalla el recorte te queda corrido." nl
         . "DpiAware=1" nl

    FileDelete, % g_IniFile
    FileAppend, % txt, % g_IniFile, UTF-16
}

; Guarda la última carpeta usada. Si el ini es de sólo lectura (pendrive
; protegido contra escritura) simplemente no pasa nada.
SaveInitialDir(dir)
{
    if (dir = "" || !InStr(FileExist(dir), "D"))
        return
    g_InitialDir := dir
    IniWrite, % dir, % g_IniFile, General, InitialDir
}

ApplyHotkey()
{
    Hotkey, IfWinActive              ; sin contexto: hotkey global
    Hotkey, % g_Hotkey, HK_Snip, On UseErrorLevel
    if (ErrorLevel)
    {
        bad := g_Hotkey
        g_Hotkey := "F8"
        Hotkey, F8, HK_Snip, On UseErrorLevel
        MsgBox, 48, %APP_NAME%, El hotkey "%bad%" del config.ini no es válido.`n`nSe usa F8 en su lugar.
    }
}


;==============================================================================
;  BANDEJA
;==============================================================================

BuildTrayMenu()
{
    Menu, Tray, NoStandard
    Menu, Tray, Add, % "Recortar ahora`t" g_Hotkey, Tray_Snip
    Menu, Tray, Add, Abrir carpeta de salida, Tray_OpenFolder
    Menu, Tray, Add, Configuración, Tray_Config
    Menu, Tray, Add
    Menu, Tray, Add, Salir, Tray_Exit
    Menu, Tray, Default, % "Recortar ahora`t" g_Hotkey
    Menu, Tray, Click, 1     ; un solo click sobre el ícono = recortar
    Menu, Tray, Tip, % APP_NAME " " APP_VERSION " - " g_Hotkey " para recortar"

    ; Corriendo como .ahk no hay ícono embebido; usamos el .ico de la carpeta.
    ; Compilado, el ícono del .exe ya es el de la bandeja.
    if (!A_IsCompiled && FileExist(A_ScriptDir "\recorto.ico"))
        Menu, Tray, Icon, % A_ScriptDir "\recorto.ico"
}

Tray_Snip:
    ; Un poco de demora para que el menú de la bandeja termine de desvanecerse
    ; y no quede su fantasma dentro de la captura.
    StartSnip(220)
return

Tray_OpenFolder:
    trayDir := (g_InitialDir != "" && InStr(FileExist(g_InitialDir), "D")) ? g_InitialDir : A_MyDocuments
    Run, % "explorer.exe """ trayDir """", , UseErrorLevel
return

Tray_Config:
    Run, % "notepad.exe """ g_IniFile """", , UseErrorLevel
    TrayTip, %APP_NAME%, Guardá el archivo y reiniciá Recorto para aplicar los cambios., 5, 1
return

Tray_Exit:
    ExitApp
return


;==============================================================================
;  IPC (segunda instancia -> instancia residente)
;==============================================================================

OnSnipRequest(wParam, lParam, msg, hwnd)
{
    ; No trabajamos dentro del handler del mensaje: se difiere a un timer para
    ; devolver el control rápido y darle tiempo a la 2da instancia a terminar
    ; de cerrarse.
    SetTimer, DeferredSnip, -150
    return 1
}

; Cursor de cruz mientras el overlay está arriba. Se hace respondiendo
; WM_SETCURSOR en vez de con SetSystemCursor para no tocar estado global de
; Windows que después habría que restaurar sí o sí.
OnSetCursor(wParam, lParam, msg, hwnd)
{
    static hCross := 0
    if (g_Overlaying && g_hOverlay && hwnd = g_hOverlay)
    {
        if (!hCross)
            hCross := DllCall("LoadCursor", "Ptr", 0, "Ptr", 32515, "Ptr")   ; IDC_CROSS
        DllCall("SetCursor", "Ptr", hCross)
        return true
    }
}


;==============================================================================
;  MODO RECORTE
;==============================================================================

StartSnip(delayMs := 0)
{
    if (g_Overlaying || g_Busy)
        return
    if (delayMs > 0)
        Sleep, % delayMs

    ; Medidas del escritorio virtual completo. SM_XVIRTUALSCREEN (76) y
    ; SM_YVIRTUALSCREEN (77) son negativos si hay monitores a la izquierda o
    ; arriba del principal, así que hay que arrastrarlos por todos lados en
    ; vez de asumir que el escritorio arranca en (0,0).
    SysGet, vx, 76
    SysGet, vy, 77
    SysGet, vw, 78
    SysGet, vh, 79
    if (vw < 1 || vh < 1)
    {
        MsgBox, 16, %APP_NAME%, No se pudo determinar el tamaño del escritorio.
        return
    }
    g_VX := vx, g_VY := vy, g_VW := vw, g_VH := vh

    ; --- 1) Congelar la pantalla ---
    g_pBmpScreen := Gdip_BitmapFromScreen(g_VX "|" g_VY "|" g_VW "|" g_VH)
    if (g_pBmpScreen <= 0)
    {
        g_pBmpScreen := 0
        MsgBox, 16, %APP_NAME%, No se pudo capturar la pantalla.
        return
    }

    ; --- 2) Versión oscurecida, pre-renderizada una sola vez ---
    ; Se deja en un DIB propio para poder usarla de fondo en cada frame con un
    ; BitBlt (copia de memoria pura), bastante más rápido que recomponerla con
    ; GDI+ en cada movimiento del mouse.
    g_hdcDark := CreateCompatibleDC()
    g_hbmDark := CreateDIBSection(g_VW, g_VH, g_hdcDark)
    g_obmDark := SelectObject(g_hdcDark, g_hbmDark)
    gD := Gdip_GraphicsFromHDC(g_hdcDark)
    Gdip_SetInterpolationMode(gD, 5)      ; NearestNeighbor: blit 1:1
    ; Base negra opaca primero: garantiza alfa 255 en todo el DIB. Sin esto,
    ; los píxeles que GDI+ no toque quedarían con alfa 0 y UpdateLayeredWindow
    ; los dibujaría transparentes (overlay invisible).
    brBase := Gdip_BrushCreateSolid(0xFF000000)
    Gdip_FillRectangle(gD, brBase, 0, 0, g_VW, g_VH)
    Gdip_DeleteBrush(brBase)
    Gdip_DrawImage(gD, g_pBmpScreen, 0, 0, g_VW, g_VH, 0, 0, g_VW, g_VH)
    brDark := Gdip_BrushCreateSolid(Round(255 * g_Opacity / 100) << 24)
    Gdip_FillRectangle(gD, brDark, 0, 0, g_VW, g_VH)
    Gdip_DeleteBrush(brDark)
    Gdip_DeleteGraphics(gD)

    ; --- 3) Buffer de composición (un solo UpdateLayeredWindow por frame) ---
    g_hdcBuf := CreateCompatibleDC()
    g_hbmBuf := CreateDIBSection(g_VW, g_VH, g_hdcBuf)
    g_obmBuf := SelectObject(g_hdcBuf, g_hbmBuf)

    ; --- 4) Ventana del overlay: layered, sin borde, sobre todos los monitores ---
    Gui, Snip:New, -Caption -DPIScale +E0x80000 +AlwaysOnTop +ToolWindow +HwndhOvTmp
    Gui, Snip:Show, Hide w1 h1, RecortoOverlay
    g_hOverlay := hOvTmp

    g_Dragging := 0
    g_x1 := 0, g_y1 := 0, g_x2 := 0, g_y2 := 0
    g_LastMX := -999999, g_LastMY := -999999
    g_ForceDraw := 1
    g_Overlaying := 1

    ; Primer frame ANTES de mostrar la ventana, así no se ve ni un parpadeo de
    ; ventana vacía. UpdateLayeredWindow además la posiciona y le da tamaño,
    ; que es como termina cubriendo monitores en coordenadas negativas.
    MouseGetPos, mx, my
    DrawOverlay(mx, my)
    DllCall("ShowWindow", "Ptr", g_hOverlay, "Int", 8)   ; SW_SHOWNA

    SetTimer, OverlayTick, 16
}

; El overlay se redibuja por timer en vez de por WM_MOUSEMOVE: es más simple y
; no depende de que la ventana tenga el foco.
OverlayTick:
    if (!g_Overlaying)
    {
        SetTimer, OverlayTick, Off
        return
    }
    MouseGetPos, tickMX, tickMY
    if (g_Dragging)
        g_x2 := tickMX, g_y2 := tickMY
    if (tickMX = g_LastMX && tickMY = g_LastMY && !g_ForceDraw)
        return
    g_LastMX := tickMX, g_LastMY := tickMY, g_ForceDraw := 0
    DrawOverlay(tickMX, tickMY)
return

; Compone un frame entero en el buffer y lo publica de una sola vez.
DrawOverlay(mx, my)
{
    if (!g_hdcBuf || !g_hOverlay)
        return

    ; Fondo: la captura ya oscurecida, copiada de memoria a memoria.
    BitBlt(g_hdcBuf, 0, 0, g_VW, g_VH, g_hdcDark, 0, 0)

    ; El Graphics se crea por frame a propósito: garantiza que GDI+ vea el
    ; resultado del BitBlt de arriba en vez de trabajar sobre un caché viejo.
    G := Gdip_GraphicsFromHDC(g_hdcBuf)
    Gdip_SetSmoothingMode(G, 3)        ; None: líneas de 1px sin difuminar
    Gdip_SetInterpolationMode(G, 5)    ; NearestNeighbor
    Gdip_SetTextRenderingHint(G, 4)    ; AntiAlias (ClearType no sirve con alfa)

    hasSel := 0
    if (g_Dragging)
    {
        GetSelRect(sx, sy, sw, sh)
        if (sw > 0 && sh > 0)
        {
            hasSel := 1
            bx := sx - g_VX, by := sy - g_VY

            ; La región elegida vuelve a la captura original, sin velo.
            Gdip_DrawImage(G, g_pBmpScreen, bx, by, sw, sh, bx, by, sw, sh)

            ; Borde: se dibuja PEGADO POR FUERA de la selección para no pisar
            ; ni un píxel de lo que se va a guardar. Blanco de 1px, con un hilo
            ; oscuro por fuera para que se vea también sobre fondo claro.
            pHair := Gdip_CreatePen(0x50000000, 1)
            Gdip_DrawRectangle(G, pHair, bx - 2, by - 2, sw + 3, sh + 3)
            Gdip_DeletePen(pHair)
            pSel := Gdip_CreatePen(0xFFFFFFFF, 1)
            Gdip_DrawRectangle(G, pSel, bx - 1, by - 1, sw + 1, sh + 1)
            Gdip_DeletePen(pSel)
        }
    }

    ; Guías horizontal y vertical, de lado a lado del escritorio virtual.
    pGuide := Gdip_CreatePen(0x70FFFFFF, 1)
    Gdip_DrawLine(G, pGuide, 0, my - g_VY, g_VW, my - g_VY)
    Gdip_DrawLine(G, pGuide, mx - g_VX, 0, mx - g_VX, g_VH)
    Gdip_DeletePen(pGuide)

    ; Etiqueta pegada al cursor: dimensiones en vivo, o una ayuda si todavía no
    ; empezó a arrastrar.
    if (hasSel)
        DrawLabel(G, mx, my, sw . " " . Chr(0x00D7) . " " . sh)
    else if (!g_Dragging)
        DrawLabel(G, mx, my, "Arrastrá para recortar " . Chr(0x00B7) . " ESC cancela")

    Gdip_DeleteGraphics(G)

    ; Un único UpdateLayeredWindow por frame: cero parpadeo.
    UpdateLayeredWindow(g_hOverlay, g_hdcBuf, g_VX, g_VY, g_VW, g_VH)
}

; Cajita oscura con texto, cerca del cursor y siempre dentro de la pantalla.
DrawLabel(G, mx, my, txt)
{
    fs := 13
    lw := 22 + Round(StrLen(txt) * fs * 0.58)
    lh := fs + 13
    lx := mx - g_VX + 18
    ly := my - g_VY + 22
    if (lx + lw > g_VW)          ; se pasa por la derecha: al otro lado
        lx := mx - g_VX - 18 - lw
    if (ly + lh > g_VH)          ; se pasa por abajo: arriba del cursor
        ly := my - g_VY - 22 - lh
    lx := Clamp(lx, 2, Max(2, g_VW - lw - 2))
    ly := Clamp(ly, 2, Max(2, g_VH - lh - 2))

    br := Gdip_BrushCreateSolid(0xE60F1420)
    Gdip_FillRoundedRectangle(G, br, lx, ly, lw, lh, 4)
    Gdip_DeleteBrush(br)
    Gdip_TextToGraphics(G, txt
        , "x" lx " y" ly " w" lw " h" lh " Center vCenter cFFFFFFFF r4 s" fs
        , "Segoe UI", g_VW, g_VH)
}

; Rectángulo de selección normalizado y recortado contra el escritorio virtual,
; en coordenadas de pantalla.
GetSelRect(ByRef sx, ByRef sy, ByRef sw, ByRef sh)
{
    x1 := Min(g_x1, g_x2), y1 := Min(g_y1, g_y2)
    x2 := Max(g_x1, g_x2), y2 := Max(g_y1, g_y2)
    x1 := Clamp(x1, g_VX, g_VX + g_VW - 1)
    y1 := Clamp(y1, g_VY, g_VY + g_VH - 1)
    x2 := Clamp(x2, g_VX, g_VX + g_VW - 1)
    y2 := Clamp(y2, g_VY, g_VY + g_VH - 1)
    sx := x1, sy := y1
    sw := x2 - x1 + 1
    sh := y2 - y1 + 1
}

CancelSnip()
{
    DestroyOverlay()
}

FinishSnip()
{
    if (!g_Overlaying)
        return
    GetSelRect(sx, sy, sw, sh)

    ; Un click sin arrastre (o casi) se toma como cancelación.
    if (sw < 5 || sh < 5)
    {
        DestroyOverlay()
        return
    }

    ; Recortar ANTES de liberar la captura de pantalla. Se clona a 24 bits RGB
    ; (0x21808) en vez de 32-ARGB: una captura de pantalla no tiene alfa, y así
    ; el PNG temporal sale en color type 2, que es el único que el generador de
    ; PDF interno puede reaprovechar tal cual (ver WritePdfFromPng).
    pCrop := Gdip_CloneBitmapArea(g_pBmpScreen, sx - g_VX, sy - g_VY, sw, sh, 0x21808)
    DestroyOverlay()

    if (pCrop <= 0)
    {
        MsgBox, 16, %APP_NAME%, No se pudo recortar la región seleccionada.
        return
    }

    ; PNG temporal en %TEMP%: es el punto de partida de las tres salidas.
    tmp := A_Temp "\recorto_" A_TickCount "_" A_MSec ".png"
    st := Gdip_SaveBitmapToFile(pCrop, tmp)
    Gdip_DisposeImage(pCrop)
    if (st != 0 || !FileExist(tmp))
    {
        FileDelete, % tmp
        MsgBox, 16, %APP_NAME%, No se pudo escribir el archivo temporal:`n%tmp%
        return
    }

    AskAndSave(tmp)
}

; Libera absolutamente todo lo que creó StartSnip(). Se llama tanto al cancelar
; como al confirmar; sin esto, veinte recortes se comen la memoria.
DestroyOverlay()
{
    SetTimer, OverlayTick, Off
    g_Overlaying := 0
    g_Dragging := 0

    if (g_hOverlay)
    {
        Gui, Snip:Destroy
        g_hOverlay := 0
    }

    ; Buffer de composición. El orden importa: primero se devuelve el bitmap
    ; original al DC, después se borra el nuestro, y recién ahí el DC.
    if (g_hdcBuf)
    {
        if (g_obmBuf)
            SelectObject(g_hdcBuf, g_obmBuf)
        if (g_hbmBuf)
            DeleteObject(g_hbmBuf)
        DeleteDC(g_hdcBuf)
    }
    g_hdcBuf := 0, g_hbmBuf := 0, g_obmBuf := 0

    ; Captura oscurecida.
    if (g_hdcDark)
    {
        if (g_obmDark)
            SelectObject(g_hdcDark, g_obmDark)
        if (g_hbmDark)
            DeleteObject(g_hbmDark)
        DeleteDC(g_hdcDark)
    }
    g_hdcDark := 0, g_hbmDark := 0, g_obmDark := 0

    ; Captura original.
    if (g_pBmpScreen)
        Gdip_DisposeImage(g_pBmpScreen)
    g_pBmpScreen := 0
}


;==============================================================================
;  GUARDADO Y CONVERSIÓN
;==============================================================================

AskAndSave(tmpPng)
{
    g_Busy := 1

    FormatTime, ts, , yyyyMMdd_HHmmss
    startIdx := (g_DefaultFormat = "pdf") ? 1 : (g_DefaultFormat = "png") ? 2 : 3
    defName  := "recorte_" ts "." g_DefaultFormat

    dest := "", idx := startIdx
    ok := ShowSaveDialog(dest, idx, defName, g_InitialDir, startIdx, "Guardar recorte")
    if (!ok || dest = "")
    {
        ; Cancelado: no queda ningún temporal dando vueltas.
        FileDelete, % tmpPng
        g_Busy := 0
        return
    }

    SplitPath, dest, , destDir, destExt
    StringLower, destExt, destExt

    ; Si lo que se tipeó no trae una extensión que sepamos manejar, se le agrega
    ; la del filtro elegido en el combo. Si sí la trae, gana la tipeada.
    if (destExt != "pdf" && destExt != "png" && destExt != "jpg" && destExt != "jpeg")
    {
        destExt := (idx = 2) ? "png" : (idx = 3) ? "jpg" : (idx = 1) ? "pdf" : g_DefaultFormat
        dest := dest "." destExt
        ; El diálogo comprobó la sobrescritura contra el nombre sin extensión,
        ; así que sobre el nombre final preguntamos nosotros.
        if (FileExist(dest))
        {
            MsgBox, 52, %APP_NAME%, El archivo ya existe:`n`n%dest%`n`n¿Reemplazarlo?
            IfMsgBox, No
            {
                FileDelete, % tmpPng
                g_Busy := 0
                return
            }
        }
    }

    SaveInitialDir(destDir)
    ConvertAndDeliver(tmpPng, dest, destExt)
    g_Busy := 0
}

; Único lugar por donde sale el archivo final. El temporal se borra siempre,
; pase lo que pase con magick.
;
; ImageMagick es opcional. Si magick.exe está, se usa tal cual (con -quality
; para JPG y -density para PDF). Si no está, o si falla, Recorto resuelve solo:
;   - JPG  -> codificador JPEG de GDI+, que acepta el mismo parámetro de calidad
;   - PDF  -> generador interno (ver WritePdfFromPng)
; Esto importa sobre todo en Windows 7: los binarios actuales de ImageMagick
; importan api-ms-win-core-synch-l1-2-0.dll, que no existe ahí, así que en
; Windows 7 magick.exe directamente no arranca.
ConvertAndDeliver(tmpPng, dest, ext)
{
    fmt := (ext = "jpeg") ? "jpg" : ext
    magick := FindMagick()

    ; --- PNG: no pasa por magick nunca, se mueve el temporal y listo ---
    if (fmt = "png")
    {
        if (!MoveTemp(tmpPng, dest))
            MsgBox, 16, %APP_NAME%, No se pudo guardar:`n%dest%
        else
            Notify(dest)
        FileDelete, % tmpPng
        return
    }

    ; --- El usuario forzó magick pero no está: hay que decírselo ---
    if (g_PdfEngine = "magick" && magick = "")
    {
        StringUpper, fmtU, fmt
        FailAndOfferPng(tmpPng, dest
            , "Falta magick.exe.`n`n"
            . "config.ini tiene PdfEngine=magick, así que Recorto no usa su generador "
            . "interno. Para guardar en " fmtU " hace falta que magick.exe (ImageMagick "
            . "portable) esté en la misma carpeta que Recorto:`n`n"
            . A_ScriptDir "\magick.exe`n`n"
            . "Poné PdfEngine=auto en config.ini para no depender de ImageMagick.")
        FileDelete, % tmpPng
        return
    }

    ; --- Camino ImageMagick ---
    usarMagick := (magick != "") && (g_PdfEngine != "interno")
    rc := ""
    if (usarMagick)
    {
        if (fmt = "pdf")
        {
            ; -units + -density fijan la resolución de la imagen, y de ahí el
            ; coder de PDF saca el MediaBox. Sin esto la página sale con un
            ; tamaño arbitrario y el recorte queda deformado.
            args := """" tmpPng """ -units PixelsPerInch -density " g_PdfDensity " """ dest """"
        }
        else
        {
            args := """" tmpPng """ -quality " g_JpgQuality " """ dest """"
        }
        ; Todo entre comillas: las rutas con espacios y acentos pasan sin romperse.
        RunWait, % """" magick """ " args, % A_Temp, Hide UseErrorLevel
        rc := ErrorLevel
        if (rc != "ERROR" && rc = 0 && FileExist(dest))
        {
            FileDelete, % tmpPng
            Notify(dest)
            return
        }
        ; magick estaba pero no sirvió (típico de Windows 7). Seguimos por el
        ; camino interno en vez de dejar al usuario sin archivo. No se borra
        ; "dest": si el usuario eligió sobrescribir un archivo que ya existía,
        ; borrarlo acá lo dejaría sin nada. Los dos generadores internos
        ; truncan el destino igual antes de escribir.
    }

    ; --- Camino interno, sin dependencias externas ---
    if (fmt = "pdf")
        err := WritePdfFromPng(tmpPng, dest, g_PdfDensity)
    else
        err := SaveJpgWithGdip(tmpPng, dest, g_JpgQuality)

    if (err != "")
    {
        extra := (rc = "" ? "" : "`n`n(ImageMagick tampoco funcionó: código " rc ")")
        FailAndOfferPng(tmpPng, dest, "No se pudo generar el archivo:`n" dest "`n`n" err extra)
    }
    else
        Notify(dest)

    FileDelete, % tmpPng
}

; Último recurso compartido: explica qué pasó y ofrece guardar el PNG, que es
; lo que ya tenemos hecho y nunca puede fallar por falta de nada.
FailAndOfferPng(tmpPng, dest, msg)
{
    if (!FileExist(tmpPng))
    {
        MsgBox, 16, %APP_NAME%, %msg%
        return
    }
    MsgBox, 52, %APP_NAME%, % msg "`n`n¿Guardar el recorte como PNG?"
    IfMsgBox, Yes
    {
        pngDest := StripExt(dest) ".png"
        if (!MoveTemp(tmpPng, pngDest))
            MsgBox, 16, %APP_NAME%, No se pudo guardar:`n%pngDest%
        else
            Notify(pngDest)
    }
}

; JPEG sin ImageMagick. El codificador JPEG de GDI+ acepta el mismo rango de
; calidad 1-100, así que el resultado es equivalente.
SaveJpgWithGdip(tmpPng, dest, quality)
{
    pB := Gdip_CreateBitmapFromFile(tmpPng)
    if (pB <= 0)
        return "GDI+ no pudo leer el PNG temporal."
    st := Gdip_SaveBitmapToFile(pB, dest, quality)
    Gdip_DisposeImage(pB)
    if (st != 0 || !FileExist(dest))
        return "El codificador JPEG de GDI+ falló (código " st ")."
    return ""
}

; Mueve el temporal al destino. FileMove entre volúmenes distintos puede fallar,
; así que cae a copiar.
MoveTemp(src, dest)
{
    FileMove, % src, % dest, 1
    if (!ErrorLevel)
        return true
    FileCopy, % src, % dest, 1
    return !ErrorLevel
}

; Busca magick.exe: primero al lado del exe (el caso portable), después en un
; par de subcarpetas típicas, y por último en el PATH.
FindMagick()
{
    cands := [ A_ScriptDir "\magick.exe"
             , A_ScriptDir "\imagemagick\magick.exe"
             , A_ScriptDir "\ImageMagick\magick.exe"
             , A_ScriptDir "\bin\magick.exe" ]
    for i, p in cands
    {
        if (FileExist(p))
            return p
    }
    VarSetCapacity(buf, 32768 * 2, 0)
    n := DllCall("SearchPathW", "Ptr", 0, "WStr", "magick.exe", "Ptr", 0
               , "UInt", 32767, "Ptr", &buf, "Ptr", 0, "UInt")
    if (n)
        return StrGet(&buf, "UTF-16")
    return ""
}

Notify(path)
{
    SplitPath, path, fn
    TrayTip, % APP_NAME, % "Guardado: " fn, 3, 1
}


;==============================================================================
;  PDF INTERNO (sin ImageMagick, sin .NET, sin nada)
;
;  El truco: dentro de un PNG, los chunks IDAT ya son un stream zlib con los
;  predictores propios de PNG aplicados fila por fila. Y PDF acepta exactamente
;  eso: /FlateDecode con /Predictor 15 ("PNG optimum"). Así que los bytes del
;  IDAT se pueden pegar en el PDF tal cual, sin descomprimir ni recomprimir, y
;  sin necesitar una librería de compresión (Windows 7 no trae ninguna usable).
;
;  Devuelve "" si salió bien, o un texto con el error.
;==============================================================================

WritePdfFromPng(pngPath, pdfPath, density)
{
    ; ---- leer el PNG entero a memoria ----
    fi := FileOpen(pngPath, "r")
    if (!IsObject(fi))
        return "No se pudo abrir el PNG temporal."
    sz := fi.Length
    VarSetCapacity(png, sz + 8, 0)
    got := fi.RawRead(png, sz)
    fi.Close()
    if (got < 57)
        return "El PNG temporal está incompleto."
    if (NumGet(png, 0, "UInt") != 0x474E5089)      ; 89 'P' 'N' 'G'
        return "El archivo temporal no es un PNG."

    ; ---- recorrer los chunks ----
    iw := 0, ih := 0, bits := 0, ctype := -1, interlace := 0
    idatPos := [], idatLen := []
    off := 8
    while (off + 12 <= got)
    {
        clen := BE32(&png, off)
        ctag := StrGet(&png + off + 4, 4, "CP0")
        dpos := off + 8
        if (dpos + clen > got)
            break
        if (ctag = "IHDR")
        {
            iw        := BE32(&png, dpos)
            ih        := BE32(&png, dpos + 4)
            bits      := NumGet(png, dpos + 8,  "UChar")
            ctype     := NumGet(png, dpos + 9,  "UChar")
            interlace := NumGet(png, dpos + 12, "UChar")
        }
        else if (ctag = "IDAT")
        {
            idatPos.Push(dpos)
            idatLen.Push(clen)
        }
        else if (ctag = "IEND")
            break
        off := dpos + clen + 4                      ; + CRC
    }

    if (!iw || !ih || !idatPos.Length())
        return "El PNG temporal no tiene datos de imagen."
    if (bits != 8 || interlace != 0 || (ctype != 2 && ctype != 0))
        return "Formato de PNG inesperado (bits=" bits " tipo=" ctype " entrelazado=" interlace ")."

    colors := (ctype = 0) ? 1 : 3
    cspace := (ctype = 0) ? "/DeviceGray" : "/DeviceRGB"
    idatTotal := 0
    for i, n in idatLen
        idatTotal += n

    ; Tamaño de página en puntos PDF (1 pt = 1/72 pulgada). Con density=96, un
    ; recorte de 960 px de ancho da 720 pt = 10 pulgadas: el tamaño físico que
    ; tenía en pantalla.
    pw := FmtNum(iw * 72.0 / density)
    ph := FmtNum(ih * 72.0 / density)

    ; "CP0" = página de códigos ANSI: escribe un byte por carácter y no mete
    ; BOM. Todo el texto del PDF es ASCII, así que es exacto.
    FileDelete, % pdfPath
    fo := FileOpen(pdfPath, "w", "CP0")
    if (!IsObject(fo))
        return "No se pudo crear el archivo PDF."

    fo.Write("%PDF-1.4`n")

    o1 := fo.Pos
    fo.Write("1 0 obj`n<< /Type /Catalog /Pages 2 0 R >>`nendobj`n")

    o2 := fo.Pos
    fo.Write("2 0 obj`n<< /Type /Pages /Kids [3 0 R] /Count 1 >>`nendobj`n")

    o3 := fo.Pos
    fo.Write("3 0 obj`n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " pw " " ph "]"
           . " /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>`nendobj`n")

    o4 := fo.Pos
    fo.Write("4 0 obj`n<< /Type /XObject /Subtype /Image"
           . " /Width " iw " /Height " ih
           . " /ColorSpace " cspace " /BitsPerComponent 8"
           . " /Filter /FlateDecode"
           . " /DecodeParms << /Predictor 15 /Colors " colors
           . " /BitsPerComponent 8 /Columns " iw " >>"
           . " /Length " idatTotal " >>`nstream`n")
    for i, p in idatPos
        fo.RawWrite(&png + p, idatLen[i])
    fo.Write("`nendstream`nendobj`n")

    ; El content stream escala la imagen unitaria al tamaño de la página.
    content := "q " pw " 0 0 " ph " 0 0 cm /Im0 Do Q`n"
    o5 := fo.Pos
    fo.Write("5 0 obj`n<< /Length " StrLen(content) " >>`nstream`n" content "endstream`nendobj`n")

    ; Tabla xref: cada entrada mide exactamente 20 bytes.
    xrefPos := fo.Pos
    fo.Write("xref`n0 6`n")
    fo.Write("0000000000 65535 f `n")
    fo.Write(Pad10(o1) " 00000 n `n")
    fo.Write(Pad10(o2) " 00000 n `n")
    fo.Write(Pad10(o3) " 00000 n `n")
    fo.Write(Pad10(o4) " 00000 n `n")
    fo.Write(Pad10(o5) " 00000 n `n")
    fo.Write("trailer`n<< /Size 6 /Root 1 0 R >>`nstartxref`n" xrefPos "`n%%EOF`n")
    fo.Close()

    if (!FileExist(pdfPath))
        return "El PDF no se escribió."
    return ""
}

; Entero de 32 bits big-endian (el orden que usa PNG).
BE32(ptr, off)
{
    return (NumGet(ptr + 0, off,     "UChar") << 24)
         | (NumGet(ptr + 0, off + 1, "UChar") << 16)
         | (NumGet(ptr + 0, off + 2, "UChar") << 8)
         |  NumGet(ptr + 0, off + 3, "UChar")
}

Pad10(n)
{
    s := n . ""
    while (StrLen(s) < 10)
        s := "0" s
    return s
}

; Número corto para el PDF: sin los ceros de relleno que mete AHK al convertir
; flotantes a texto.
FmtNum(x)
{
    s := Round(x, 3) . ""
    if (InStr(s, "."))
    {
        s := RTrim(s, "0")
        s := RTrim(s, ".")
    }
    return (s = "") ? "0" : s
}


;==============================================================================
;  DIÁLOGO DE GUARDADO
;
;  Se llama GetSaveFileNameW directo en vez de usar FileSelectFile porque el
;  comando de AHK sólo admite UN filtro (más "todos los archivos"), y acá hacen
;  falta tres en un orden concreto, hay que preseleccionar uno y hay que saber
;  cuál eligió el usuario. Nada de eso se puede con FileSelectFile.
;==============================================================================

ShowSaveDialog(ByRef outFile, ByRef outIndex, defName, initDir, startIndex, title)
{
    ; Filtro: pares "descripción<NUL>patrón<NUL>", cerrado con un NUL extra. No
    ; se puede armar como string normal de AHK porque los NUL cortan la cadena,
    ; así que se escribe carácter por carácter en un buffer.
    seq := [ "PDF (*.pdf)",  "*.pdf"
           , "PNG (*.png)",  "*.png"
           , "JPG (*.jpg)",  "*.jpg;*.jpeg" ]
    total := 1
    for i, s in seq
        total += StrLen(s) + 1
    VarSetCapacity(filt, total * 2, 0)
    off := 0
    for i, s in seq
    {
        StrPut(s, &filt + off * 2, StrLen(s) + 1, "UTF-16")
        off += StrLen(s) + 1
    }

    ; Buffer de entrada/salida del nombre de archivo.
    VarSetCapacity(fileBuf, 32768 * 2, 0)
    StrPut(defName, &fileBuf, 32767, "UTF-16")

    VarSetCapacity(dirBuf, (StrLen(initDir) + 1) * 2, 0)
    if (initDir != "")
        StrPut(initDir, &dirBuf, StrLen(initDir) + 1, "UTF-16")
    VarSetCapacity(titBuf, (StrLen(title) + 1) * 2, 0)
    StrPut(title, &titBuf, StrLen(title) + 1, "UTF-16")

    ; Offsets de OPENFILENAMEW. Cambian entre 32 y 64 bits por el alineado de
    ; los punteros, así que van a mano en vez de asumir un layout.
    if (A_PtrSize = 8)
    {
        cb := 152
        oOwner := 8, oFilter := 24, oIdx := 44, oFile := 48, oMaxFile := 56
        oInitDir := 80, oTitle := 88, oFlags := 96
    }
    else
    {
        cb := 88
        oOwner := 4, oFilter := 12, oIdx := 24, oFile := 28, oMaxFile := 32
        oInitDir := 44, oTitle := 48, oFlags := 52
    }

    VarSetCapacity(ofn, cb, 0)
    NumPut(cb,         ofn, 0,        "UInt")
    NumPut(g_hIPC,     ofn, oOwner,   "Ptr")
    NumPut(&filt,      ofn, oFilter,  "Ptr")
    NumPut(startIndex, ofn, oIdx,     "UInt")
    NumPut(&fileBuf,   ofn, oFile,    "Ptr")
    NumPut(32767,      ofn, oMaxFile, "UInt")
    if (initDir != "")
        NumPut(&dirBuf, ofn, oInitDir, "Ptr")
    NumPut(&titBuf,    ofn, oTitle,   "Ptr")

    ; OVERWRITEPROMPT | HIDEREADONLY | NOCHANGEDIR | PATHMUSTEXIST
    ; | EXPLORER | ENABLESIZING
    NumPut(0x0088080E, ofn, oFlags, "UInt")

    ; A propósito NO se usa lpstrDefExt: si Windows completara la extensión
    ; solo, agregaría siempre la misma sin mirar qué filtro quedó elegido. La
    ; resolvemos nosotros al volver, en AskAndSave().
    ret := DllCall("comdlg32\GetSaveFileNameW", "Ptr", &ofn, "UInt")
    if (!ret)
        return false

    outFile  := StrGet(&fileBuf, "UTF-16")
    outIndex := NumGet(ofn, oIdx, "UInt")
    return (outFile != "")
}


;==============================================================================
;  UTILIDADES
;==============================================================================

; Vista+: SetProcessDPIAware. Win8.1+: SetProcessDpiAwareness. Win10 1703+:
; SetProcessDpiAwarenessContext (per-monitor v2). Se prueba de la mejor a la
; peor comprobando primero si la función existe, porque en Windows 7 las dos
; primeras no están y hay que caer a la última sin hacer ruido.
MakeProcessDpiAware()
{
    IniRead, want, % A_ScriptDir "\config.ini", General, DpiAware, 1
    if (want = 0)
        return

    hUser := DllCall("GetModuleHandle", "Str", "user32", "Ptr")
    if (hUser && DllCall("GetProcAddress", "Ptr", hUser, "AStr", "SetProcessDpiAwarenessContext", "Ptr"))
    {
        ; -4 = DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
        if (DllCall("SetProcessDpiAwarenessContext", "Ptr", -4, "UInt"))
            return
    }

    hShcore := DllCall("LoadLibrary", "Str", "shcore.dll", "Ptr")
    if (hShcore && DllCall("GetProcAddress", "Ptr", hShcore, "AStr", "SetProcessDpiAwareness", "Ptr"))
    {
        ; 2 = PROCESS_PER_MONITOR_DPI_AWARE
        if (DllCall("shcore\SetProcessDpiAwareness", "UInt", 2, "Int") = 0)
            return
    }

    DllCall("SetProcessDPIAware")   ; Vista+, siempre está en Windows 7
}

Clamp(v, lo, hi)
{
    return (v < lo) ? lo : (v > hi) ? hi : v
}

StripExt(path)
{
    SplitPath, path, , dir, ext, nameNoExt
    return (dir != "") ? dir "\" nameNoExt : nameNoExt
}

App_Exit:
    DestroyOverlay()
    if (g_pToken)
    {
        Gdip_Shutdown(g_pToken)
        g_pToken := 0
    }
ExitApp


;==============================================================================
;  LIBRERÍA
;  Va al final para que la sección de auto-ejecución de arriba no pueda caer
;  dentro de ella por accidente.
;==============================================================================
#Include %A_ScriptDir%\Gdip_All.ahk
