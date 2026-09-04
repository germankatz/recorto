<div align="center">

<img src="docs/icono.png" alt="Recorto" width="120">

# Recorto

**Recortá un pedazo de la pantalla y guardalo como PDF.**

Portable: una carpeta que copiás a un pendrive y anda.
Sin instalador, sin registro, sin .NET.

[![Descargar](https://img.shields.io/badge/Descargar%20recorto.exe-v1.0.0-7C5CFF?style=for-the-badge&logo=windows&logoColor=white)](https://github.com/germankatz/recorto/releases/latest/download/recorto.exe)
&nbsp;
![Windows](https://img.shields.io/badge/Windows-7%20SP1%20%E2%86%92%2011-2D7FF9?style=for-the-badge)
&nbsp;
![Licencia](https://img.shields.io/badge/Licencia-MIT-555?style=for-the-badge)

</div>

<hr>

## Cómo se usa

1. Ejecutás `recorto.exe`. Queda en la bandeja del sistema.
2. **F8** congela la pantalla y la oscurece.
3. Arrastrás: la región elegida se ve nítida, con el tamaño en vivo al lado del
   cursor.
4. Al soltar elegís dónde guardar. **PDF**, PNG o JPG.

**ESC** o clic derecho cancela.

Anclalo a la barra de tareas y el clic abre el recorte directo, sin abrir una
segunda copia del programa.

<hr>

## Descarga

| Archivo | |
|---|---|
| **[`recorto.exe`](https://github.com/germankatz/recorto/releases/latest/download/recorto.exe)** | 32 bits. El recomendado: anda en Windows de 32 y 64 bits |
| [`recorto_x64.exe`](https://github.com/germankatz/recorto/releases/latest/download/recorto_x64.exe) | 64 bits |

Windows 7 SP1 o superior. `config.ini` se crea solo al lado del ejecutable.

<hr>

## Arrancar con Windows

Dejá la carpeta donde vaya a vivir, y después:

1. `Win + R` → escribí `shell:startup` → Enter. Se abre la carpeta de Inicio.
2. Arrastrá `recorto.exe` ahí **con el botón derecho** y soltá → *Crear iconos
   de acceso directo*.
3. Clic derecho en el acceso directo → *Propiedades* → al final de **Destino**
   agregá un espacio y `/tray`:

```
"C:\...\recorto.exe" /tray
```

Sin `/tray` te abriría el modo recorte cada vez que prendés la máquina. Con
`/tray` arranca callado, sólo el ícono en la bandeja.

No toca el registro: es un acceso directo en una carpeta, lo borrás y listo.

<hr>

## Bandeja

| | |
|---|---|
| Recortar ahora | También con un clic en el ícono |
| Abrir carpeta de salida | La última que usaste |
| Configuración | Abre `config.ini` |
| Salir | |

<hr>

## Configuración

`config.ini`, al lado del ejecutable. Los cambios se aplican al reiniciar.

| Clave | Por defecto | |
|---|---|---|
| `Hotkey` | `F8` | `^`=Ctrl `!`=Alt `+`=Shift `#`=Win. Ej: `^!s` |
| `DefaultFormat` | `pdf` | `pdf`, `png` o `jpg` |
| `JpgQuality` | `92` | 1-100 |
| `PdfDensity` | `96` | DPI. Más alto = página más chica |
| `InitialDir` | | Carpeta del diálogo. Se actualiza sola |
| `OverlayOpacity` | `45` | Oscurecimiento, 0-95 % |
| `PdfEngine` | `auto` | `auto`, `magick` o `interno` |
| `DpiAware` | `1` | Ponelo en `0` si con escalado el recorte queda corrido |

<hr>

## ImageMagick

No hace falta: Recorto genera el PDF y el JPG por su cuenta.

Si querés usarlo igual, poné `magick.exe` del
[paquete portable](https://github.com/ImageMagick/ImageMagick/releases) al lado
del ejecutable. **En Windows 7 no lo pongas**: los binarios actuales importan
`api-ms-win-core-synch-l1-2-0.dll`, que ahí no existe.

<hr>

## Compilar

Necesitás [AutoHotkey 1.1](https://www.autohotkey.com/download/ahk.zip) (no v2),
edición Unicode.

```bat
build.cmd "C:\ruta\a\AutoHotkey\Compiler"
```

El ícono, el nombre y la versión se embeben desde las directivas
`;@Ahk2Exe-...` del principio de `recorto.ahk`.

<hr>

<div align="center">

MIT · [`Gdip_All.ahk`](https://github.com/marius-sucan/AHK-GDIp-Library-Compilation)
de Marius Șucan, sobre el trabajo original de Tariq Porter

</div>
