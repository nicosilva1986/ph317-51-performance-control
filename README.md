# Predator PH317-51 Performance Control

Evidence-led thermal, fan, Turbo Boost, power-policy, and driver hygiene tooling for the Acer Predator PH317-51 (Intel Core i7-7700HQ / GTX 1060 generation).

> Estado: desarrollo privado y experimental. Validado inicialmente en una sola PH317-51. No ejecutar todavía en otro equipo.

## Por qué existe

En la máquina de referencia encontramos tres problemas distintos que las herramientas genéricas mezclaban:

1. El perfil local de ThrottleStop imponía un límite artificial de 28x, aunque el i7-7700HQ admite los ratios Intel 38/36/35/34 según cantidad de núcleos activos.
2. El modo automático de ventiladores reaccionaba demasiado tarde. El firmware Acer ya ofrecía una interfaz WMI/ACPI legítima y reversible; no fue necesario escribir directamente al EC.
3. Windows conservaba bindings de drivers de otros equipos, incluido un filtro forense CRU activo sobre ambos discos internos.

El objetivo no es "overclockear" ni aplicar tweaks ciegos. Es recuperar el rendimiento diseñado por Intel/Acer, medir cada cambio y mantener una ruta de rollback.

## Resultado medido hasta ahora

Con la misma carga NumPy/OpenBLAS AVX2/FMA de diez minutos y el mismo límite 28x:

| Perfil | Máxima | Promedio | p95 | Iteraciones | WHEA |
|---|---:|---:|---:|---:|---:|
| Ventiladores Auto | 91 °C | 86,8 °C | 90 °C | 153 | 0 |
| Ventiladores Max | 79 °C | 76,3 °C | 79 °C | 166 | 0 |

Max redujo la máxima 12 °C, redujo el promedio 10,5 °C y mejoró el throughput 8,5 %. Ambos ventiladores llegaron a 6122 RPM. La prueba completa saneada está en [`evidence/benchmarks`](evidence/benchmarks/2026-08-21-fan-auto-vs-max.json).

## Diseño

- **Fan controller:** un único escritor privilegiado decide `AUTO` o `MAX` con carga por núcleo, temperatura, velocidad de subida e histéresis.
- **Watchdog fail-closed:** verifica heartbeat, estado, integridad y ejecución; una falla lleva a `MAX`, nunca a un supuesto estado saludable.
- **Native Turbo:** usa Turbo Boost/Speed Shift de Intel y un plan Windows reproducible. No manipula voltajes ni límites eléctricos en la primera fase.
- **Driver hygiene:** inventario, hashes, backups dobles y rebind reversible. Los binarios de terceros no se publican.
- **Evidence first:** toda afirmación de rendimiento debe enlazar una carga reproducible, datos térmicos y ausencia/presencia de WHEA.

Ver [uso y pruebas](docs/usage.md), [arquitectura](docs/architecture.md), [inventario inicial](docs/hardware-and-driver-baseline.md), [plan Turbo nativo](docs/native-turbo-plan.md) y [recuperación](docs/recovery-and-rollback.md).

## Seguridad

Este proyecto ejecuta código como `SYSTEM` y puede interactuar con firmware, energía y drivers. Por eso:

- no deshabilita VBS/HVCI, UAC, BD PROCHOT ni protecciones térmicas;
- no incluye claves BitLocker, seriales, instance IDs completos ni backups del registro;
- no redistribuye PredatorSense, ThrottleStop ni paquetes de drivers;
- no elimina drivers con `/force`;
- no considera un benchmark verde como autorización para publicar o instalar en otros modelos.

El driver `ThrottleStop.sys` 3.0.0.0 observado localmente coincide con la versión afectada por CVE-2025-7771. El diseño permanente evita depender de ese driver. Ver [SECURITY.md](SECURITY.md).

## Alcance actual

- Modelo inicial: Acer Predator PH317-51.
- CPU inicial: Intel Core i7-7700HQ.
- Firmware probado: BIOS V1.22 y clase WMI `AcerGamingFunction`.
- Windows probado: Windows 11 build 26200.
- Otros Acer/Nitro/Predator: **no asumidos compatibles**.

## Fuentes principales

- [Intel Core i7-7700HQ](https://www.intel.com/content/www/us/en/products/sku/97185/intel-core-i77700hq-processor-6m-cache-up-to-3-80-ghz/specifications.html)
- [Intel Turbo Boost](https://www.intel.com/content/www/us/en/support/articles/000030893/processors.html)
- [Microsoft power performance tuning](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/hardware/power/power-performance-tuning)
- [Linux `acer-wmi.c`](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/acer-wmi.c)
- [Acer PH317-51 support](https://www.acer.com/ar-es/support/product-support/Predator_PH317-51/downloads)
- [NVD CVE-2025-7771](https://nvd.nist.gov/vuln/detail/CVE-2025-7771)

## Publicación

El repositorio permanece privado mientras se completa la sanitización, el instalador transaccional, las pruebas de watchdog y la validación Turbo CPU+GPU. Hacerlo público será una decisión separada.
