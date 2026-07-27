# Renode Issue #915 Reproduction — STM32H563 Bare-Metal Support

This repository reproduces [renode/renode#915](https://github.com/renode/renode/issues/915): bare-metal firmware for the ST NUCLEO-H563ZI board (STM32H563ZIT6, Cortex-M33) hangs in `Error_Handler()` when run on Renode.

## The Problem

CubeMX-generated HAL firmware for the STM32H5 series polls ready flags in PWR, RCC, and FLASH during `SystemClock_Config()`. Without proper peripheral models for the H5 family, these registers are either absent or return zero, causing infinite polling loops that make the firmware hang before reaching `main()`.

Specifically:
- **PWR**: `VOSRDY` flag never asserts after voltage-scaling configuration
- **RCC**: HSE/HSI48/PLL ready bits never assert after oscillator enable
- **FLASH**: `ACR` read-back mismatch after latency write causes `HAL_ERROR`

## Firmware

`basic_peripheral_test.elf` is a minimal CubeMX-generated project verified on real hardware. It:
1. Configures the MPU and system clocks (HSE bypass + PLL1 → 250 MHz)
2. Initializes GPIO, IWDG, RNG, USART3
3. Turns on three user LEDs (green PB0, yellow PF4, red PG4)
4. Prints `Welcome to STM32 world !` on USART3 (ST-Link VCP, 115200 8N1)
5. Loops; user button (PC13/EXTI13) toggles the LEDs

## Branches

- **`before-fix`**: Test FAILS — demonstrates the bug. The platform uses only stock Renode types (tags for PWR/RCC/FLASH), so the firmware hangs.
- **`after-fix`**: Test PASSES — requires Renode built with the STM32H5 peripheral models from [nburek/renode-infrastructure@915-stm32h563_support](https://github.com/nburek/renode-infrastructure/tree/915-stm32h563_support). The platform uses proper `STM32H5_PWR`, `STM32H5_RCC`, `STM32H5_FlashController`, etc.

## Running Locally

```bash
# With Renode installed or built from source:
renode-test test.robot
```

## CI

The GitHub Actions workflow tests against both `v1.16.1` (stable) and `master` of Renode. On the `before-fix` branch, both are expected to fail. On `after-fix`, the test passes against the patched Renode fork.
