# Instalador del servidor "Los Varchar2"

Instalador de mods para entrar al servidor de Minecraft **Los Varchar2** (Minecraft Java **1.21.1** con **NeoForge**).

## ⬇️ Descargar

**[Descargar el instalador (Cliente-Amigos-SinExe.zip)](https://github.com/DiegoRobleM/LosVarchar2-Instalador/releases/latest/download/Cliente-Amigos-SinExe.zip)**

Este enlace siempre baja la última versión. Las versiones anteriores están en [Releases](https://github.com/DiegoRobleM/LosVarchar2-Instalador/releases).

## Cómo se instala

1. Ten Minecraft Java instalado y abre el launcher al menos una vez.
2. Ten **Java 21** ([Temurin 21](https://adoptium.net/temurin/releases/?version=21)).
3. Antes de extraer el zip: clic derecho → **Propiedades** → marca **Desbloquear** → Aceptar.
4. Extrae el zip completo y haz doble clic en **`Instalar.bat`**.
5. En el launcher elige el perfil **NeoForge** y juega. La dirección del servidor te la pasa Diego.

Las instrucciones completas están en [`LEEME.txt`](LEEME.txt).

## Cuando hay mods nuevos

Vuelve a abrir `Instalar.bat`: descarga la lista de mods actualizada y baja solo lo que falta. Solo hay que descargar un zip nuevo de aquí cuando cambia el instalador mismo.

## ¿Es seguro?

Es un script de PowerShell casero, sin firma digital. Por eso Windows puede mostrar "Windows protegió tu PC" (elige **Más información → Ejecutar de todas formas**). El código está completo en este repositorio, se puede revisar:

- `Instalar.bat` abre `archivos/instalador-gui.ps1` (la ventana del instalador).
- Los mods se descargan desde **Modrinth**; NeoForge, desde **maven.neoforged.net**.
- La lista de mods sale de `archivos/mods.json` (y de una copia actualizada en un Gist).
- No descarga ni ejecuta otros scripts.

---
Este repositorio se actualiza solo desde el proyecto del servidor (`scripts/publicar/publicar-instalador.ps1`). No edites aquí directamente.
