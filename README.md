# Roblox Studio MCP — instalación en Windows

Este proyecto le da a un asistente de IA remoto "ojos y manos" dentro de tu sesión de Roblox Studio (sin Rojo):

```
Asistente IA ──HTTPS──> Cloudflare Tunnel ──> Servidor MCP (Node, puerto 3333, token Bearer)
                                                   │  puente local 127.0.0.1:44755
                                                   ▼
                                    Plugin de Studio (long-polling por HttpService)
```

- **Servidor MCP** (`src/`): Node + TypeScript, transporte *Streamable HTTP* en `/mcp`, protegido con `MCP_TOKEN`. Saca capturas de la ventana de Studio con PowerShell.
- **Plugin** (`plugin/RobloxStudioMCP.server.lua`): consulta el puente local, ejecuta los comandos y devuelve los resultados. Funciona en Edit y durante los tests de Play (contextos `edit`, `server`, `client`).

## 1. Instalar Node.js
Instala **Node.js 20 LTS o superior** desde https://nodejs.org (o `winget install OpenJS.NodeJS.LTS`). Comprueba la instalación en PowerShell:
```powershell
node -v
npm -v
```

## 2. Compilar el servidor
Descomprime `roblox-studio-mcp.zip`, por ejemplo en `C:\roblox-studio-mcp`, y luego:
```powershell
cd C:\roblox-studio-mcp
npm install
npm run build
npm test        # opcional: prueba con un plugin simulado
```

## 3. Configurar el token
El token es la contraseña del servidor. Usa uno largo y aleatorio:
```powershell
$b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b) -replace '[+/=]',''
```
Puedes definirlo en la sesión (`$env:MCP_TOKEN = "..."`) o dejar que `scripts\start.ps1` lo genere y lo guarde en `.mcp-token`.

Variables opcionales: `MCP_PORT` (3333 por defecto), `MCP_HOST` (127.0.0.1), `BRIDGE_PORT` (44755) y `BRIDGE_SECRET`, que añade un secreto compartido entre el plugin y el puente; ver "Seguridad".

## 4. Instalar el plugin
```powershell
Copy-Item plugin\RobloxStudioMCP.server.lua "$env:LOCALAPPDATA\Roblox\Plugins\RobloxStudioMCP.lua"
```
(Si la carpeta no existe, abre Studio y entra en *Plugins → Plugins Folder*.) Reinicia Studio. Aparecerá una pestaña **MCP** con el botón **MCP Bridge**, que activa o desactiva la conexión.

## 5. Permitir HTTP al plugin
La primera vez que el plugin intente conectar con `127.0.0.1`, Studio pedirá permiso: **Allow**. Si lo rechazaste, ve a *Plugins → Manage Plugins → Roblox Studio MCP (icono de lápiz/permisos)* y habilita **HTTP Requests** para `127.0.0.1`.
No hace falta activar `HttpEnabled` en *Game Settings*, porque los plugins usan su propio permiso. Para que el plugin funcione también durante Play, ten activado *File → Studio Settings → (los plugins se cargan en Play)*; es el comportamiento por defecto.

## 6. Arrancar el servidor
```powershell
.\scripts\start.ps1
# o:  $env:MCP_TOKEN="..."; npm start
```
Debe mostrar `MCP endpoint: http://127.0.0.1:3333/mcp`. En la ventana Output de Studio verás `[MCP] edit bridge: connected`.
Puedes comprobarlo en `http://127.0.0.1:44755/health`.

> Si PowerShell bloquea scripts: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

## 7. Exponerlo con Cloudflare Tunnel
Instala cloudflared: `winget install --id Cloudflare.cloudflared`.

**Opción A: túnel rápido (sin cuenta, URL temporal):**
```powershell
cloudflared tunnel --url http://localhost:3333
```
Te dará una URL `https://xxxx.trycloudflare.com`. La URL del conector MCP es `https://xxxx.trycloudflare.com/mcp`, con la cabecera `Authorization: Bearer <tu token>`. La URL cambia cada vez que reinicias el túnel.

**Opción B: túnel con nombre (URL fija, requiere un dominio en Cloudflare):**
```powershell
cloudflared tunnel login
cloudflared tunnel create studio-mcp
cloudflared tunnel route dns studio-mcp studio-mcp.tudominio.com
```
Crea `%USERPROFILE%\.cloudflared\config.yml`:
```yaml
tunnel: studio-mcp
credentials-file: C:\Users\TU_USUARIO\.cloudflared\<ID-DEL-TUNEL>.json
ingress:
  - hostname: studio-mcp.tudominio.com
    service: http://localhost:3333
  - service: http_status:404
```
Y arráncalo con `cloudflared tunnel run studio-mcp` (o instálalo como servicio con `cloudflared service install`).
Opcionalmente puedes añadir **Cloudflare Access** (service token) como segunda capa de autenticación.

Expón **solo el puerto 3333**, nunca el puerto del puente (44755).

## 8. Conectar el asistente
Añade un conector MCP de tipo *Streamable HTTP* con la URL `https://.../mcp` y la cabecera `Authorization: Bearer <token>`.

## Herramientas
| Herramienta | Qué hace |
|---|---|
| `get_studio_state` | Estado del puente por contexto, modo (edit/play), selección, lugar y cámara |
| `list_tree` | Árbol de instancias (`path`, `depth`) |
| `get_properties` / `set_properties` | Leer y escribir propiedades y atributos |
| `create_instance` / `delete_instance` / `clone_instance` / `move_instance` | Crear, borrar, clonar y reparentar |
| `get_script_source` / `set_script_source` | Leer y editar scripts (vía ScriptEditorService) |
| `run_luau` | Ejecutar Luau y devolver lo impreso, los valores de retorno y los errores |
| `get_selection` / `set_selection` | Selección de Studio |
| `set_camera` | Mover la cámara (CFrame, posición + lookAt o `focus` sobre una instancia) |
| `start_playtest` / `stop_playtest` | Play (F5) o Run (F8) mediante StudioTestService |
| `get_output_log` | Mensajes recientes de Output |
| `screenshot` | Captura de la ventana de Studio (PNG, ~1280 px de ancho) |

Todas las modificaciones en Edit se registran con **ChangeHistoryService**: puedes deshacerlas con Ctrl+Z ("MCP: ...").
Durante un test, pasa `context: "server"` o `"client"` para actuar sobre el juego en ejecución.

### Convención JSON de tipos
```json
{"$type":"Vector3","value":[0,5,0]}
{"$type":"CFrame","value":[x,y,z,r00,r01,r02,r10,r11,r12,r20,r21,r22]}
{"$type":"CFrame","position":[0,10,0],"lookAt":[0,0,0]}
{"$type":"Color3","value":[1,0,0]}      o  {"$type":"Color3","hex":"#ff0000"}
{"$type":"UDim2","value":[0.5,0,0.5,0]}
{"$type":"Enum","enum":"Material","value":"Neon"}
{"$type":"BrickColor","value":"Bright red"}
{"$type":"Instance","path":"game.Workspace.Model.Part"}
```
También se admiten `Vector2`, `UDim`, `NumberRange` y `Rect`. Las rutas usan puntos (`Workspace.Model.Part`). Los nombres que contienen puntos van entre corchetes: `Workspace["Mi.Parte"]`.

## Limitaciones conocidas
- **Play/Stop:** `StudioTestService:ExecutePlayModeAsync` / `ExecuteRunModeAsync` y `EndTest` son APIs recientes. Si tu versión de Studio no las permite desde un plugin, inicia o detén el test a mano (F5 / Shift+F5) y el resto seguirá funcionando. `stop_playtest` necesita que el contexto `server` del test esté conectado.
- **Contexto `client`:** Roblox puede bloquear HttpService en el DataModel del cliente. En ese caso solo se conectan `edit` y `server`. Desde `server` se puede inspeccionar casi todo el juego, incluido el personaje.
- **Undo** solo existe en Edit: los cambios hechos durante Play se pierden al parar, como siempre en Studio.
- **run_luau** usa `loadstring` con seguridad de plugin. El timeout cancela el hilo, pero un bucle infinito sin `task.wait` congelará Studio.
- **Captura de pantalla:** solo funciona en Windows. Usa `PrintWindow` (funciona aunque la ventana esté tapada). Si la ventana está minimizada, la restaura. Con algunos drivers el viewport 3D puede salir negro; en ese caso usa `mode: "screen"`, que captura el monitor principal (Studio debe estar visible). Para probarla a mano: `powershell -File scripts\screenshot-studio.ps1 -Out C:\temp\s.png`.
- Si hay varias ventanas de Studio, se captura la primera y el plugin de cada una compite por los comandos. Lo mejor es tener un solo lugar abierto.
- Los clics y el teclado reales (input humano) no se simulan: se actúa mediante la API, que es más preciso.

## Seguridad
- Quien tenga el token puede **ejecutar código arbitrario dentro de Studio** (con permisos de plugin) y ver tu pantalla de Studio. Trátalo como una contraseña, no lo publiques y rótalo si se filtra (borra `.mcp-token`).
- El servidor escucha solo en `127.0.0.1`. El acceso externo pasa únicamente por cloudflared (HTTPS).
- El puente (44755) acepta solo conexiones locales. En equipos compartidos, define `BRIDGE_SECRET` y pon el mismo valor en `SECRET_OVERRIDE`, al principio del archivo del plugin.
- Cierra el túnel (Ctrl+C) cuando no lo uses y desactiva el botón **MCP Bridge** para cortar el control.
- Guarda tu lugar o usa control de versiones: aunque hay undo, `run_luau` puede hacer cambios grandes.
