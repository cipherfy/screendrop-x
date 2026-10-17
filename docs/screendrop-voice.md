# Screendrop Voice: funciones de audio

Screendrop Voice es un fork de [Screendrop](https://github.com/fayazara/screendrop) centrado en la calidad de la voz grabada para tutoriales, recorridos y presentaciones de herramientas. Este documento resume lo que el fork añade sobre el original.

Todo el procesamiento ocurre en el Mac. La voz no se envía a ningún servicio, y los másters originales de cada grabación nunca se modifican: los ajustes viven en el documento del proyecto y se aplican al reproducir y al exportar.

## Recorrido de la señal

```
Micrófono (PCM 24 bits)
 → Aislamiento de voz (render previo, opcional)
 → Trim de entrada → High-pass → Match EQ → EQ de 5 bandas
 → Proximity → Expander → Compressor → De-esser → Saturación (4x)
 → Fader de voz (o ganancia automática de loudness)
 → Limitador de true peak por pista
 → Suma con el audio del sistema (fader y limitador propios)
 → Limitador de mezcla (en el export)
```

Preview, export de video, export de solo audio y Share usan exactamente el mismo procesamiento: lo que se oye en Studio es lo que se exporta.

## 1. Captura

- **Micrófono sin pérdida.** La pista del micrófono se graba en PCM de 24 bits, mono, a 48 kHz, en lugar de AAC a 96 kbps. Es idéntica bit a bit a lo que entrega el micrófono, y el EQ y la compresión no sacan a la luz artefactos de codificación. Ocupa unos 9.7 MB por minuto con el audio del sistema incluido. El audio del sistema sigue en AAC.
- **Micrófono identificado.** El manifiesto de cada grabación guarda qué micrófono se usó, para recordar el perfil de cada uno.
- **Prueba de micrófono.** *Check Microphone…*, en el menú del micrófono de la barra de grabación, mide 2.5 s de silencio y 6 s leyendo una frase, por el mismo camino que usa la grabadora. Da consejos concretos sobre:
  - nivel, con picos ideales entre -12 y -6 dBFS;
  - clipping;
  - ruido de la habitación;
  - distancia entre voz y ruido;
  - zumbido de red de 50/60 Hz.

  No guarda nada en disco.

## 2. Aislamiento de voz

- Usa el aislamiento de voz de Apple en el dispositivo (`AUSoundIsolation`, modelo de alta calidad) para quitar ruido de fondo, eco de la habitación y teclado.
- Se renderiza **una vez** dentro del paquete del proyecto, a unas 80 veces tiempo real (unos 7 s por cada 10 minutos de narración). Después se sustituye solo la pista del micrófono, con alineación exacta a la muestra.
- Cantidades: **Off, 75 %, 90 %, 100 %**, con **75 % por defecto** en cada proyecto. La mezcla es lineal: al 75 % la habitación baja unos 12 dB y al 90 % unos 20 dB. Dejar un poco suele sonar más natural.
- En el banco de pruebas, la toma de un condensador USB en un escritorio pasó de 23.4 a 45.6 dB de SNR.
- Los exports renderizan el aislamiento automáticamente si falta. No se aplica al audio de reemplazo importado.

## 3. Perfil de voz

El inspector describe la voz que se quiere, y Studio resuelve a partir de eso una cadena concreta.

| Control | Opciones | Qué hace |
|---|---|---|
| **Character** | Clear, Broadcast | **Clear**: casi neutral, pensado para la inteligibilidad. **Broadcast**: locución pulida calibrada con referencias reales, con su propia curva objetivo, presencia en medios (1.4 kHz), compresión estable y saturación ligera |
| **Intensity** | 0–100 % (60 % por defecto) | Escala solo el carácter |
| **Loudness** | Off, -16 LUFS, -14 LUFS (por defecto) | Ajusta el fader de voz para llegar al objetivo |

Además, toda voz recibe unas **correcciones base** que no dependen del micrófono ni escalan con la intensidad: high-pass a 80 Hz, control de proximidad, de-esser y un expansor suave para la habitación que quede tras el aislamiento.

El **match EQ** está siempre activo por defecto. Su interruptor está en el channel strip.

### Análisis automático de la toma

Antes de aplicar el perfil, Studio mide la narración que realmente suena (la versión aislada, si el aislamiento está activo):

- **Loudness y ruido.** Calcula el trim de entrada que lleva la toma a -26 LUFS, el nivel para el que están calibrados los umbrales de la cadena.
- **Fundamental.** Detecta el pitch por autocorrelación para situar la banda de "body" justo por encima de la fundamental de tu voz.
- **Espectro a largo plazo**, que usa el match EQ.

Hasta 3 minutos analiza la narración completa; en grabaciones más largas toma 6 fragmentos de 30 s repartidos de principio a fin. El análisis y el ajuste de loudness tardan unos 2 segundos con cualquier duración. El análisis se guarda con el proyecto.

### Match EQ

- Seis campanas por octava, de 250 Hz a 8 kHz.
- Corrige el 70 % de la diferencia medida respecto a la curva objetivo.
- Límites asimétricos: recortes hasta -6 dB, realces hasta +4.5 dB. Las bandas sin contenido real no se tocan, para no levantar ruido.
- La curva objetivo por defecto es un punto de partida. Se puede rehacer a partir de locuciones de referencia:

  ```bash
  build/voice-bank/bin/voice-bank target referencia1.wav referencia2.wav
  ```

### Loudness

- Calcula la ganancia de voz que deja la voz procesada en el objetivo, pasando por la cadena, el fader y el limitador, e itera hasta compensar lo que recorta el limitador. En las pruebas queda a menos de 0.15 LU del objetivo.
- Mover el slider **Voice** a mano pasa el objetivo a *Off*.
- Ajusta la voz, no la mezcla completa: el audio del sistema queda relativo a su propio fader.

### Calibrar un carácter con referencias

Broadcast se calibró con dos locuciones de referencia: su curva objetivo es el promedio de ambas, y su EQ y su dinámica se ajustaron para acercarse a ellas. Para comparar los caracteres sobre una grabación propia, a -14 LUFS y en tu Mac:

```bash
build/render-voice-ab "RUTA/AL/PROYECTO.screendroprec" "RUTA/DE/SALIDA"
```

Genera tres WAV: Clear, Broadcast y la versión anterior de Broadcast. No modifica el proyecto.

### Memoria por micrófono

Se recuerda el último perfil (carácter, intensidad, loudness) usado con cada micrófono. Un micrófono nuevo empieza con los valores por defecto.

## 4. Channel strip

*Channel Strip…* abre todas las etapas de la cadena para editarlas a mano:

| Etapa | Parámetros |
|---|---|
| Input | Trim |
| High-pass | Frecuencia; 12 o 24 dB/octava |
| EQ | Body, Mud, Presence, Harshness, Air: ganancia, frecuencia y Q |
| Match EQ | Interruptor *Match Target EQ*; 250 Hz, 500 Hz, 1 kHz, 2 kHz, 4 kHz, 8 kHz |
| Proximity | Banda dinámica: frecuencia, umbral, rango |
| Expander | Umbral, ratio, rango, release |
| Compressor | Umbral, ratio, knee, attack, release, makeup |
| De-esser | Frecuencia, umbral, rango |
| Saturation | Drive, mix, warmth (armónicos pares), a 4x de sobremuestreo |

- Una **curva de EQ** muestra la respuesta real, calculada con los mismos coeficientes que ejecuta el DSP.
- La primera edición convierte la cadena en **personalizada**: el perfil queda en pausa, salvo el objetivo de loudness, que sigue activo. *Reset to Profile* devuelve el control al perfil.

## 5. Mezcla, limitación y monitorización

- **Faders separados**: *Voice* (-24 a +24 dB) y *System Audio* (-60, que silencia, a +12 dB). Antes había un único volumen para todo.
- **Limitador de true peak a -1 dBTP**, con lookahead, en cada pista y sobre la mezcla al exportar. Sustituye al clipping duro del original.
- **Latencia uniforme.** Todas las pistas se retrasan lo mismo (3.8 ms), así que voz y sistema siguen alineados con cualquier ajuste. En el export el audio queda unos 7 ms detrás de la imagen, algo imperceptible.
- **Voice Processing (A/B)**: al apagarlo se oye la voz sin procesar, **al mismo loudness** y con la misma latencia, para comparar el sonido sin que influya el volumen.
- **Medidores en vivo**, en un acordeón *Meters* del panel (cerrado por defecto) y siempre visibles en el channel strip:
  - entrada y salida, con caída tipo PPM;
  - reducción de ganancia del expansor, compresor, de-esser y limitador;
  - loudness de corto plazo (EBU R128, 3 s) frente al objetivo.

## 6. Convivencia con el Screendrop original

| | Original | Screendrop Voice |
|---|---|---|
| Bundle ID | `com.fayazahmed.Screendrop` | `com.cipherfy.ScreendropVoice` |
| Datos | `Application Support/Screendrop/` | `Application Support/Screendrop Voice/` |
| Exports | `Pictures/Screendrop/` | `Pictures/Screendrop Voice/` |
| Atajos | ⌥1–⌥5 | ⌥⇧1–⌥⇧5 |
| Actualizaciones | Sparkle (feed del autor) | Desactivadas hasta tener un feed propio |

Ambas apps pueden estar instaladas a la vez sin compartir grabaciones, credenciales ni preferencias.

## 7. Verificación

El proyecto no tiene target de tests, así que el fork incluye un **banco de voz** con voces sintéticas en español y variantes con problemas conocidos (ruido, zumbido, teclado, habitación, dureza, delgadez, proximidad, nivel bajo, saturación y condensador en escritorio), además de scripts que comprueban cada pieza con resultados esperados conocidos:

| Script | Comprueba |
|---|---|
| `scripts/voice-bank/generate.sh` | Banco, medición y comparación con la línea base |
| `check-microphone-capture` | Captura sin pérdida y lectura en Studio |
| `check-audio-processing` | Ganancias por pista, limitación y cambios sin clics |
| `check-voice-chain` | Cada etapa de la cadena, aliasing, true peak y A/B |
| `check-voice-isolation` | Alineación, reducción de ruido y renders en caché |
| `check-voice-profile` | Perfiles, pitch, match EQ, normalización y pipeline completo |
| `check-voice-tools` | Curva de EQ, medidores y consejos de la prueba de micrófono |

El medidor de loudness está validado contra EBU Tech 3341 y contra el filtro `ebur128` de ffmpeg. Los detalles y comandos están en [voice-bank.md](voice-bank.md).

## Pendiente

- Ducking del audio del sistema bajo la voz.
- Normalización de loudness sobre la mezcla completa.
- Recalibrar la curva objetivo con locuciones de referencia reales.
- Transcribir a partir de la voz aislada.
- Corregir un fallo heredado del original: Share y la subida a la nube ignoran el audio de reemplazo importado.
- Distribución: feed propio de Sparkle, notarización e instalación en `/Applications`.
