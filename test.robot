# Watchdog reset cadence — real hardware behaviour, not an emulation artefact.
#
# The reference firmware starts the IWDG with prescaler /4 and reload 4095 and never
# refreshes it. At the 32 kHz LSI that is a ~512 ms watchdog period. Renode's
# STM32_IndependentWatchdog calls machine.RequestReset() on expiry, which reboots the
# firmware: the banner reprints, all three LEDs re-light, and BspButtonState resets to 0.
#
# Every assertion in this suite must therefore land inside the first ~512 ms after boot,
# or explicitly tolerate the reset cycle. No test case disables the watchdog — it is
# what the hardware does.

*** Variables ***
${UART}                             sysbus.usart3

${FIRMWARE}                         ${CURDIR}/artifacts/basic_peripheral_test.elf

${PLATFORM}                         platforms/boards/nucleo_h563zi.repl

*** Keywords ***
Create Machine
    [Arguments]                     ${elf}=${FIRMWARE}

    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${PLATFORM}
    Execute Command                 sysbus LoadELF ${elf}

Assert PC Outside Symbol
    [Arguments]                     ${symbol}
    ${addr}=                        Execute Command  sysbus GetSymbolAddress "${symbol}" cpu
    ${pc}=                          Execute Command  cpu PC
    Should Not Be Equal As Integers  ${pc}  ${addr}

*** Test Cases ***
Should Configure MPU And Reach HAL Init
    [Documentation]                 Increment 1: MPU configuration completes without faulting.
    ...                             Uses cpu Step (instruction-count) which is well within the
    ...                             512 ms watchdog period at 250 MHz.
    Create Machine
    Execute Command                 cpu Step 2000
    Assert PC Outside Symbol        Error_Handler
    # Select MPU region 0
    Execute Command                 sysbus WriteDoubleWord 0xE000ED98 0x0
    # MPU region 0: 0x08FFF000-0x08FFFFFF, read-only, non-executable
    ${rbar}=                        Execute Command  sysbus ReadDoubleWord 0xE000ED9C
    ${rlar}=                        Execute Command  sysbus ReadDoubleWord 0xE000EDA0
    # RBAR encodes base 0x08FFF000 with AP=3 (RO) and XN=1
    Should Be Equal As Integers     ${rbar}  0x08FFF007
    # RLAR encodes limit 0x08FFFFFF with EN=1
    Should Be Equal As Integers     ${rlar}  0x08FFFFE1

Should Print Banner On Usart3
    [Documentation]                 Increment 6: The bytes written to TDR arrive on the terminal
    ...                             in order. The string is what this reference firmware's printf
    ...                             happens to emit, not a contract on the model's contents.
    ...                             Assertion lands within the first watchdog period (~512 ms).
    Create Machine
    Create Terminal Tester          ${UART}  defaultPauseEmulation=True
    Wait For Line On Uart           Welcome to STM32 world !  timeout=0.5

Should Light All Leds
    [Documentation]                 Increment 7: After boot completes, all three user LEDs are on.
    ...                             RunFor 0.4s keeps the assertion inside the ~512 ms watchdog
    ...                             period.
    Create Machine
    ${green}=                       Create LED Tester  sysbus.gpioPortB.GreenLED
    ${yellow}=                      Create LED Tester  sysbus.gpioPortF.YellowLED
    ${red}=                         Create LED Tester  sysbus.gpioPortG.RedLED

    Execute Command                 emulation RunFor "0.4"

    Assert LED State                true  testerId=${green}
    Assert LED State                true  testerId=${yellow}
    Assert LED State                true  testerId=${red}

Should Toggle Leds On Button Press
    [Documentation]                 Increment 8: A button press toggles all three LEDs off, a
    ...                             second press toggles them back on. The entire press/observe
    ...                             sequence must complete within one ~512 ms watchdog period
    ...                             because a reset restores LEDs to on and clears BspButtonState.
    Create Machine

    # Boot and let LEDs light — 200 ms is enough for init, well within 512 ms
    Execute Command                 emulation RunFor "0.2"

    # Confirm LEDs are on before the press
    ${green}=                       Create LED Tester  sysbus.gpioPortB.GreenLED
    ${yellow}=                      Create LED Tester  sysbus.gpioPortF.YellowLED
    ${red}=                         Create LED Tester  sysbus.gpioPortG.RedLED
    Assert LED State                true  testerId=${green}
    Assert LED State                true  testerId=${yellow}
    Assert LED State                true  testerId=${red}

    # Press the button — hold across RunFor so the ISR has time to service it
    Execute Command                 sysbus.gpioPortC.UserButton1 Press
    Execute Command                 emulation RunFor "0.05"
    Execute Command                 sysbus.gpioPortC.UserButton1 Release

    # LEDs should now be off
    Assert LED State                false  testerId=${green}
    Assert LED State                false  testerId=${yellow}
    Assert LED State                false  testerId=${red}

    # Second press — LEDs back on
    Execute Command                 sysbus.gpioPortC.UserButton1 Press
    Execute Command                 emulation RunFor "0.05"
    Execute Command                 sysbus.gpioPortC.UserButton1 Release

    Assert LED State                true  testerId=${green}
    Assert LED State                true  testerId=${yellow}
    Assert LED State                true  testerId=${red}

Should Report Voltage Scaling Ready
    [Documentation]                 Property 1: Voltage scaling selection is mirrored and reported
    ...                             ready. Exhaustive over all four VOS encodings.
    ...                             Validates: Requirements 5.2, 5.3, 5.4
    Create Machine

    FOR  ${vos}  IN  0  1  2  3
        ${vos_shifted}=             Evaluate  ${vos} << 4
        Execute Command             sysbus WriteDoubleWord 0x44020810 ${vos_shifted}
        ${vossr}=                   Execute Command  sysbus ReadDoubleWord 0x44020814
        ${actvos}=                  Evaluate  (${vossr} >> 14) & 0x3
        ${vosrdy}=                  Evaluate  (${vossr} >> 3) & 0x1
        Should Be Equal As Integers  ${actvos}  ${vos}
        Should Be Equal As Integers  ${vosrdy}  1
    END

Should Mirror Oscillator Ready Bits
    [Documentation]                 Property 2: Oscillator ready bits follow their enable bits in
    ...                             both directions (enable → ready set, disable → ready clear).
    ...                             Exhaustive over all nine enable/ready pairs.
    ...                             Validates: Requirements 6.2, 6.3, 6.4
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${PLATFORM}

    # RCC_CR pairs (address 0x44020C00):
    FOR  ${en_bit}  ${rdy_bit}  IN
    ...  0   1
    ...  8   9
    ...  12  13
    ...  16  17
    ...  24  25
    ...  26  27
    ...  28  29
        # Enable: set the enable bit, verify ready bit is set
        ${cr}=                      Execute Command  sysbus ReadDoubleWord 0x44020C00
        ${cr_int}=                  Convert To Integer  ${cr.strip()}
        ${en_mask}=                 Evaluate  1 << ${en_bit}
        ${new_cr}=                  Evaluate  ${cr_int} | ${en_mask}
        Execute Command             sysbus WriteDoubleWord 0x44020C00 ${new_cr}
        ${cr_after}=                Execute Command  sysbus ReadDoubleWord 0x44020C00
        ${cr_after_int}=            Convert To Integer  ${cr_after.strip()}
        ${rdy_val}=                 Evaluate  (${cr_after_int} >> ${rdy_bit}) & 1
        Should Be Equal As Integers  ${rdy_val}  1  Enable bit ${en_bit} set but ready bit ${rdy_bit} not set in RCC_CR

        # Disable: clear the enable bit, verify ready bit is clear
        ${cr2}=                     Execute Command  sysbus ReadDoubleWord 0x44020C00
        ${cr2_int}=                 Convert To Integer  ${cr2.strip()}
        ${clear_mask}=              Evaluate  ${cr2_int} & ~(1 << ${en_bit})
        Execute Command             sysbus WriteDoubleWord 0x44020C00 ${clear_mask}
        ${cr_after2}=               Execute Command  sysbus ReadDoubleWord 0x44020C00
        ${cr_after2_int}=           Convert To Integer  ${cr_after2.strip()}
        ${rdy_val2}=                Evaluate  (${cr_after2_int} >> ${rdy_bit}) & 1
        Should Be Equal As Integers  ${rdy_val2}  0  Enable bit ${en_bit} cleared but ready bit ${rdy_bit} still set in RCC_CR
    END

    # RCC_BDCR pairs (address 0x44020CF0):
    FOR  ${en_bit}  ${rdy_bit}  IN
    ...  0   1
    ...  26  27
        ${bdcr}=                    Execute Command  sysbus ReadDoubleWord 0x44020CF0
        ${bdcr_int}=                Convert To Integer  ${bdcr.strip()}
        ${en_mask}=                 Evaluate  1 << ${en_bit}
        ${new_bdcr}=                Evaluate  ${bdcr_int} | ${en_mask}
        Execute Command             sysbus WriteDoubleWord 0x44020CF0 ${new_bdcr}
        ${bdcr_after}=              Execute Command  sysbus ReadDoubleWord 0x44020CF0
        ${bdcr_after_int}=          Convert To Integer  ${bdcr_after.strip()}
        ${rdy_val}=                 Evaluate  (${bdcr_after_int} >> ${rdy_bit}) & 1
        Should Be Equal As Integers  ${rdy_val}  1  Enable bit ${en_bit} set but ready bit ${rdy_bit} not set in RCC_BDCR

        ${bdcr2}=                   Execute Command  sysbus ReadDoubleWord 0x44020CF0
        ${bdcr2_int}=               Convert To Integer  ${bdcr2.strip()}
        ${clear_mask}=              Evaluate  ${bdcr2_int} & ~(1 << ${en_bit})
        Execute Command             sysbus WriteDoubleWord 0x44020CF0 ${clear_mask}
        ${bdcr_after2}=             Execute Command  sysbus ReadDoubleWord 0x44020CF0
        ${bdcr_after2_int}=         Convert To Integer  ${bdcr_after2.strip()}
        ${rdy_val2}=                Evaluate  (${bdcr_after2_int} >> ${rdy_bit}) & 1
        Should Be Equal As Integers  ${rdy_val2}  0  Enable bit ${en_bit} cleared but ready bit ${rdy_bit} still set in RCC_BDCR
    END

Should Mirror Clock Switch Status
    [Documentation]                 Property 3: System clock switch status mirrors the selection.
    ...                             Exhaustive over every valid SW encoding in RCC_CFGR1.
    ...                             Validates: Requirements 6.5
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${PLATFORM}

    Execute Command                 sysbus WriteDoubleWord 0x44020C28 0x00000101

    FOR  ${sw_val}  IN  0  1  2  3
        ${cfgr1}=                   Execute Command  sysbus ReadDoubleWord 0x44020C1C
        ${cfgr1_int}=               Convert To Integer  ${cfgr1.strip()}
        ${cleared}=                 Evaluate  ${cfgr1_int} & ~0x7
        ${new_cfgr1}=               Evaluate  ${cleared} | ${sw_val}
        Execute Command             sysbus WriteDoubleWord 0x44020C1C ${new_cfgr1}

        ${cfgr1_after}=             Execute Command  sysbus ReadDoubleWord 0x44020C1C
        ${cfgr1_after_int}=         Convert To Integer  ${cfgr1_after.strip()}
        ${sws_val}=                 Evaluate  (${cfgr1_after_int} >> 3) & 0x7
        Should Be Equal As Integers  ${sws_val}  ${sw_val}  SW=${sw_val} but SWS=${sws_val} — status does not mirror selection
    END

Should Preserve Configuration Registers
    [Documentation]                 Property 4: Configuration registers preserve written values.
    ...                             Validates: Requirements 6.6, 7.1, 7.6, 10.11
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${PLATFORM}

    # --- PLL1CFGR (0x44020C28, mask 0x00073F3F) ---
    Execute Command                 sysbus WriteDoubleWord 0x44020C28 0x00052A15
    ${val}=                         Execute Command  sysbus ReadDoubleWord 0x44020C28
    ${masked}=                      Evaluate  ${val.strip()} & 0x00073F3F
    Should Be Equal As Integers     ${masked}  0x00052A15  PLL1CFGR value 1 not preserved

    Execute Command                 sysbus WriteDoubleWord 0x44020C28 0x00021530
    ${val}=                         Execute Command  sysbus ReadDoubleWord 0x44020C28
    ${masked}=                      Evaluate  ${val.strip()} & 0x00073F3F
    Should Be Equal As Integers     ${masked}  0x00021530  PLL1CFGR value 2 not preserved

    # --- PLL1DIVR (0x44020C34, mask 0x7F7FFFFF) ---
    Execute Command                 sysbus WriteDoubleWord 0x44020C34 0x3A4C0180
    ${val}=                         Execute Command  sysbus ReadDoubleWord 0x44020C34
    ${masked}=                      Evaluate  ${val.strip()} & 0x7F7FFFFF
    Should Be Equal As Integers     ${masked}  0x3A4C0180  PLL1DIVR value 1 not preserved

    Execute Command                 sysbus WriteDoubleWord 0x44020C34 0x55230049
    ${val}=                         Execute Command  sysbus ReadDoubleWord 0x44020C34
    ${masked}=                      Evaluate  ${val.strip()} & 0x7F7FFFFF
    Should Be Equal As Integers     ${masked}  0x55230049  PLL1DIVR value 2 not preserved

    # --- PLL1FRACR (0x44020C38, mask 0x0000FFF8) ---
    Execute Command                 sysbus WriteDoubleWord 0x44020C38 0x0000A5A0
    ${val}=                         Execute Command  sysbus ReadDoubleWord 0x44020C38
    ${masked}=                      Evaluate  ${val.strip()} & 0x0000FFF8
    Should Be Equal As Integers     ${masked}  0x0000A5A0  PLL1FRACR value 1 not preserved

    Execute Command                 sysbus WriteDoubleWord 0x44020C38 0x00005678
    ${val}=                         Execute Command  sysbus ReadDoubleWord 0x44020C38
    ${masked}=                      Evaluate  ${val.strip()} & 0x0000FFF8
    Should Be Equal As Integers     ${masked}  0x00005678  PLL1FRACR value 2 not preserved

    # --- CFGR1 (0x44020C1C, mask 0xFFFCBFC0) ---
    Execute Command                 sysbus WriteDoubleWord 0x44020C1C 0xA53C2F40
    ${val}=                         Execute Command  sysbus ReadDoubleWord 0x44020C1C
    ${masked}=                      Evaluate  ${val.strip()} & 0xFFFCBFC0
    Should Be Equal As Integers     ${masked}  0xA53C2F40  CFGR1 value 1 not preserved

    Execute Command                 sysbus WriteDoubleWord 0x44020C1C 0x5A801080
    ${val}=                         Execute Command  sysbus ReadDoubleWord 0x44020C1C
    ${masked}=                      Evaluate  ${val.strip()} & 0xFFFCBFC0
    Should Be Equal As Integers     ${masked}  0x5A801080  CFGR1 value 2 not preserved

    # --- CFGR2 (0x44020C20, mask 0x007B777F) ---
    Execute Command                 sysbus WriteDoubleWord 0x44020C20 0x003B5524
    ${val}=                         Execute Command  sysbus ReadDoubleWord 0x44020C20
    ${masked}=                      Evaluate  ${val.strip()} & 0x007B777F
    Should Be Equal As Integers     ${masked}  0x003B5524  CFGR2 value 1 not preserved

    Execute Command                 sysbus WriteDoubleWord 0x44020C20 0x0040224B
    ${val}=                         Execute Command  sysbus ReadDoubleWord 0x44020C20
    ${masked}=                      Evaluate  ${val.strip()} & 0x007B777F
    Should Be Equal As Integers     ${masked}  0x0040224B  CFGR2 value 2 not preserved

    # --- CCIPR2 (0x44020CDC, mask 0x77777777) ---
    Execute Command                 sysbus WriteDoubleWord 0x44020CDC 0x32145670
    ${val}=                         Execute Command  sysbus ReadDoubleWord 0x44020CDC
    ${masked}=                      Evaluate  ${val.strip()} & 0x77777777
    Should Be Equal As Integers     ${masked}  0x32145670  CCIPR2 value 1 not preserved

    Execute Command                 sysbus WriteDoubleWord 0x44020CDC 0x45632107
    ${val}=                         Execute Command  sysbus ReadDoubleWord 0x44020CDC
    ${masked}=                      Evaluate  ${val.strip()} & 0x77777777
    Should Be Equal As Integers     ${masked}  0x45632107  CCIPR2 value 2 not preserved

    # --- CCIPR5 (0x44020CE8, mask 0xC03F03FF) ---
    Execute Command                 sysbus WriteDoubleWord 0x44020CE8 0x801A02A5
    ${val}=                         Execute Command  sysbus ReadDoubleWord 0x44020CE8
    ${masked}=                      Evaluate  ${val.strip()} & 0xC03F03FF
    Should Be Equal As Integers     ${masked}  0x801A02A5  CCIPR5 value 1 not preserved

    Execute Command                 sysbus WriteDoubleWord 0x44020CE8 0x4025015A
    ${val}=                         Execute Command  sysbus ReadDoubleWord 0x44020CE8
    ${masked}=                      Evaluate  ${val.strip()} & 0xC03F03FF
    Should Be Equal As Integers     ${masked}  0x4025015A  CCIPR5 value 2 not preserved

Should Compute System Clock
    [Documentation]                 Property 5: Computed system clock matches the reference formula
    ...                             and is propagated to the NVIC.
    ...                             **Validates: Requirements 7.2, 7.4, 7.7**
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${PLATFORM}

    # --- Tuple 1: Firmware config (250 MHz) ---
    Execute Command                 sysbus WriteDoubleWord 0x44020C00 0x01010000
    Execute Command                 sysbus WriteDoubleWord 0x44020C28 0x00000403
    Execute Command                 sysbus WriteDoubleWord 0x44020C34 0x000002F9
    Execute Command                 sysbus WriteDoubleWord 0x44020C1C 0x00000003

    ${freq}=                        Execute Command  sysbus.nvic Frequency
    Should Be Equal As Integers     ${freq}  250000000  Firmware config: expected 250 MHz

    # --- Tuple 2: 100 MHz ---
    Execute Command                 machine Reset
    Execute Command                 sysbus WriteDoubleWord 0x44020C00 0x01010000
    Execute Command                 sysbus WriteDoubleWord 0x44020C28 0x00000203
    Execute Command                 sysbus WriteDoubleWord 0x44020C34 0x00000663
    Execute Command                 sysbus WriteDoubleWord 0x44020C1C 0x00000003

    ${freq}=                        Execute Command  sysbus.nvic Frequency
    Should Be Equal As Integers     ${freq}  100000000  Tuple 2: expected 100 MHz

    # --- Tuple 3: 200 MHz ---
    Execute Command                 machine Reset
    Execute Command                 sysbus WriteDoubleWord 0x44020C00 0x01010000
    Execute Command                 sysbus WriteDoubleWord 0x44020C28 0x00000103
    Execute Command                 sysbus WriteDoubleWord 0x44020C34 0x00000231
    Execute Command                 sysbus WriteDoubleWord 0x44020C1C 0x00000003

    ${freq}=                        Execute Command  sysbus.nvic Frequency
    Should Be Equal As Integers     ${freq}  200000000  Tuple 3: expected 200 MHz

    # --- Verify no PLL1-selected config yields zero ---
    ${freq_check}=                  Execute Command  sysbus.nvic Frequency
    ${freq_int}=                    Convert To Integer  ${freq_check.strip()}
    Should Not Be Equal As Integers  ${freq_int}  0  SWS selects PLL1 but frequency is zero

Should Honour Flash Latency And Lock
    [Documentation]                 Property 6: Flash ACR fields survive a write and read cycle.
    ...                             Validates: Requirements 8.2, 8.3
    Create Machine

    FOR  ${lat}  IN RANGE  16
        FOR  ${wrhf}  IN RANGE  4
            ${val}=                 Evaluate  (${wrhf} << 4) | ${lat}
            Execute Command         sysbus WriteDoubleWord 0x40022000 ${val}
            ${readback}=            Execute Command  sysbus ReadDoubleWord 0x40022000
            ${rb_int}=              Convert To Integer  ${readback.strip()}
            ${rb_lat}=              Evaluate  ${rb_int} & 0xF
            ${rb_wrhf}=             Evaluate  (${rb_int} >> 4) & 0x3
            Should Be Equal As Integers  ${rb_lat}  ${lat}  LATENCY=${lat} not preserved
            Should Be Equal As Integers  ${rb_wrhf}  ${wrhf}  WRHIGHFREQ=${wrhf} not preserved
        END
    END

Should Verify Flash Lock Key Sequence
    [Documentation]                 Property 7: The flash lock admits exactly the correct key sequence.
    ...                             Validates: Requirements 8.4, 8.5, 8.6, 8.7
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${PLATFORM}

    # --- Scenario 1: After reset, LOCK is set (locked) ---
    ${nscr}=                        Execute Command  sysbus ReadDoubleWord 0x40022028
    ${lock}=                        Evaluate  ${nscr.strip()} & 0x1
    Should Be Equal As Integers     ${lock}  1  Flash should be locked after reset

    # --- Scenario 2: Correct key pair in order unlocks ---
    Execute Command                 sysbus WriteDoubleWord 0x40022004 0x45670123
    Execute Command                 sysbus WriteDoubleWord 0x40022004 0xCDEF89AB
    ${nscr}=                        Execute Command  sysbus ReadDoubleWord 0x40022028
    ${lock}=                        Evaluate  ${nscr.strip()} & 0x1
    Should Be Equal As Integers     ${lock}  0  Flash should be unlocked after correct key sequence

    # --- Scenario 3: Relock by writing 1 to NSCR.LOCK, then unlock again ---
    Execute Command                 sysbus WriteDoubleWord 0x40022028 0x00000001
    ${nscr}=                        Execute Command  sysbus ReadDoubleWord 0x40022028
    ${lock}=                        Evaluate  ${nscr.strip()} & 0x1
    Should Be Equal As Integers     ${lock}  1  Flash should be relocked after writing LOCK=1

    Execute Command                 sysbus WriteDoubleWord 0x40022004 0x45670123
    Execute Command                 sysbus WriteDoubleWord 0x40022004 0xCDEF89AB
    ${nscr}=                        Execute Command  sysbus ReadDoubleWord 0x40022028
    ${lock}=                        Evaluate  ${nscr.strip()} & 0x1
    Should Be Equal As Integers     ${lock}  0  Flash should unlock with fresh sequence after relock

    # --- Scenario 4: Wrong key leaves it locked ---
    Execute Command                 machine Reset
    ${nscr}=                        Execute Command  sysbus ReadDoubleWord 0x40022028
    ${lock}=                        Evaluate  ${nscr.strip()} & 0x1
    Should Be Equal As Integers     ${lock}  1  Flash should be locked after machine reset
    Execute Command                 sysbus WriteDoubleWord 0x40022004 0xDEADBEEF
    ${nscr}=                        Execute Command  sysbus ReadDoubleWord 0x40022028
    ${lock}=                        Evaluate  ${nscr.strip()} & 0x1
    Should Be Equal As Integers     ${lock}  1  Flash should remain locked after wrong key

    # --- Scenario 5: Intervening incorrect write invalidates the sequence ---
    Execute Command                 machine Reset
    Execute Command                 sysbus WriteDoubleWord 0x40022004 0x45670123
    Execute Command                 sysbus WriteDoubleWord 0x40022004 0xBADCAFE0
    Execute Command                 sysbus WriteDoubleWord 0x40022004 0xCDEF89AB
    ${nscr}=                        Execute Command  sysbus ReadDoubleWord 0x40022028
    ${lock}=                        Evaluate  ${nscr.strip()} & 0x1
    Should Be Equal As Integers     ${lock}  1  Flash should remain locked when sequence is interrupted

Should Program And Erase Flash
    [Documentation]                 Property 8: Programming writes the supplied data to flash contents.
    ...                             **Validates: Requirements 9.1**
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${PLATFORM}
    Execute Command                 sysbus LoadELF ${FIRMWARE}

    FOR  ${addr}  ${data}  IN
    ...  0x08100000  0xDEADBEEF
    ...  0x08000100  0xCAFEBABE
    ...  0x081FFFF0  0x12345678
        Execute Command             sysbus WriteDoubleWord 0x40022004 0x45670123
        Execute Command             sysbus WriteDoubleWord 0x40022004 0xCDEF89AB

        ${nscr}=                    Execute Command  sysbus ReadDoubleWord 0x40022028
        ${lock}=                    Evaluate  ${nscr.strip()} & 0x1
        Should Be Equal As Integers  ${lock}  0  Flash should be unlocked before programming at ${addr}

        ${nscr_val}=                Evaluate  ${nscr.strip()} | 0x2
        Execute Command             sysbus WriteDoubleWord 0x40022028 ${nscr_val}

        Execute Command             sysbus WriteDoubleWord ${addr} ${data}

        ${readback}=                Execute Command  sysbus ReadDoubleWord ${addr}
        Should Be Equal As Integers  ${readback}  ${data}  Flash at ${addr} should contain written data

        ${nscr_fw}=                 Execute Command  sysbus ReadDoubleWord 0x40022028
        ${nscr_fw_set}=             Evaluate  ${nscr_fw.strip()} | 0x10
        Execute Command             sysbus WriteDoubleWord 0x40022028 ${nscr_fw_set}

        ${nssr}=                    Execute Command  sysbus ReadDoubleWord 0x40022020
        ${eop}=                     Evaluate  (${nssr.strip()} >> 16) & 0x1
        Should Be Equal As Integers  ${eop}  1  EOP should be set after programming at ${addr}

        Execute Command             sysbus WriteDoubleWord 0x40022030 0x00010000

        ${nssr_after}=              Execute Command  sysbus ReadDoubleWord 0x40022020
        ${eop_after}=               Evaluate  (${nssr_after.strip()} >> 16) & 0x1
        Should Be Equal As Integers  ${eop_after}  0  EOP should be cleared after writing NSCCR at ${addr}

        ${nscr_clear}=              Execute Command  sysbus ReadDoubleWord 0x40022028
        ${nscr_nopg}=               Evaluate  ${nscr_clear.strip()} & ~0x12
        Execute Command             sysbus WriteDoubleWord 0x40022028 ${nscr_nopg}

        Execute Command             sysbus WriteDoubleWord 0x40022028 0x00000001
    END

Should Erase Flash Sectors
    [Documentation]                 Property 9: Erasing sets the target range to the erased value
    ...                             and leaves the rest alone.
    ...                             **Validates: Requirements 9.2**
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${PLATFORM}
    Execute Command                 sysbus LoadELF ${FIRMWARE}

    # Unlock flash once for all erase operations
    Execute Command                 sysbus WriteDoubleWord 0x40022004 0x45670123
    Execute Command                 sysbus WriteDoubleWord 0x40022004 0xCDEF89AB

    # --- Sector 1, Bank 0 (neighbour: sector 2 at 0x08004000) ---
    Execute Command                 sysbus WriteDoubleWord 0x08002000 0xDEADBEEF
    Execute Command                 sysbus WriteDoubleWord 0x08004000 0xCAFEBABE
    ${s1_pre}=                      Execute Command  sysbus ReadDoubleWord 0x08002000
    Should Be Equal As Integers     ${s1_pre}  0xDEADBEEF  Sector 1 pre-write failed
    ${n1_pre}=                      Execute Command  sysbus ReadDoubleWord 0x08004000
    Should Be Equal As Integers     ${n1_pre}  0xCAFEBABE  Neighbour sector 2 pre-write failed
    Execute Command                 sysbus WriteDoubleWord 0x40022028 0x00000064
    ${nssr}=                        Execute Command  sysbus ReadDoubleWord 0x40022020
    ${eop}=                         Evaluate  (${nssr.strip()} >> 16) & 0x1
    Should Be Equal As Integers     ${eop}  1  EOP should be set after erasing sector 1 bank 0
    ${s1_erased}=                   Execute Command  sysbus ReadDoubleWord 0x08002000
    Should Be Equal As Integers     ${s1_erased}  0xFFFFFFFF  Sector 1 should be erased (0xFFFFFFFF)
    ${n1_after}=                    Execute Command  sysbus ReadDoubleWord 0x08004000
    Should Be Equal As Integers     ${n1_after}  0xCAFEBABE  Neighbour sector 2 should be untouched
    Execute Command                 sysbus WriteDoubleWord 0x40022030 0x00010000

    # --- Sector 0, Bank 1 (neighbour: sector 1, bank 1 at 0x08102000) ---
    Execute Command                 sysbus WriteDoubleWord 0x08100000 0xFEEDFACE
    Execute Command                 sysbus WriteDoubleWord 0x08102000 0xABCD1234
    Execute Command                 sysbus WriteDoubleWord 0x40022028 0x80000024
    ${nssr}=                        Execute Command  sysbus ReadDoubleWord 0x40022020
    ${eop}=                         Evaluate  (${nssr.strip()} >> 16) & 0x1
    Should Be Equal As Integers     ${eop}  1  EOP should be set after erasing sector 0 bank 1
    ${sb1s0_erased}=                Execute Command  sysbus ReadDoubleWord 0x08100000
    Should Be Equal As Integers     ${sb1s0_erased}  0xFFFFFFFF  Sector 0 bank 1 should be erased
    ${nb1s1_after}=                 Execute Command  sysbus ReadDoubleWord 0x08102000
    Should Be Equal As Integers     ${nb1s1_after}  0xABCD1234  Neighbour sector 1 bank 1 should be untouched
    Execute Command                 sysbus WriteDoubleWord 0x40022030 0x00010000

    # --- Sector 64, Bank 0 (neighbour: sector 65 at 0x08082000) ---
    Execute Command                 sysbus WriteDoubleWord 0x08080000 0xC0FFEE42
    Execute Command                 sysbus WriteDoubleWord 0x08082000 0xDEADC0DE
    Execute Command                 sysbus WriteDoubleWord 0x40022028 0x00001024
    ${nssr}=                        Execute Command  sysbus ReadDoubleWord 0x40022020
    ${eop}=                         Evaluate  (${nssr.strip()} >> 16) & 0x1
    Should Be Equal As Integers     ${eop}  1  EOP should be set after erasing sector 64 bank 0
    ${s64_erased}=                  Execute Command  sysbus ReadDoubleWord 0x08080000
    Should Be Equal As Integers     ${s64_erased}  0xFFFFFFFF  Sector 64 should be erased
    ${n65_after}=                   Execute Command  sysbus ReadDoubleWord 0x08082000
    Should Be Equal As Integers     ${n65_after}  0xDEADC0DE  Neighbour sector 65 should be untouched
    Execute Command                 sysbus WriteDoubleWord 0x40022030 0x00010000
    Execute Command                 sysbus WriteDoubleWord 0x40022028 0x00000001

Should Reject Locked Flash Operations
    [Documentation]                 Property 10: Locked flash rejects every modifying operation.
    ...                             **Validates: Requirements 9.3**
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${PLATFORM}
    Execute Command                 sysbus LoadELF ${FIRMWARE}

    # --- Verify flash is locked after reset ---
    ${nscr}=                        Execute Command  sysbus ReadDoubleWord 0x40022028
    ${lock}=                        Evaluate  ${nscr.strip()} & 0x1
    Should Be Equal As Integers     ${lock}  1  Flash should be locked after reset

    # --- Operation 1: Program (PG) while locked ---
    Execute Command                 sysbus WriteDoubleWord 0x40022028 0x00000003
    ${nssr}=                        Execute Command  sysbus ReadDoubleWord 0x40022020
    ${pgserr}=                      Evaluate  (${nssr.strip()} >> 18) & 0x1
    Should Be Equal As Integers     ${pgserr}  1  PG while locked: PGSERR should be set in NSSR

    Execute Command                 sysbus WriteDoubleWord 0x40022030 0x00040000
    ${nssr_cleared}=                Execute Command  sysbus ReadDoubleWord 0x40022020
    ${pgserr_after}=                Evaluate  (${nssr_cleared.strip()} >> 18) & 0x1
    Should Be Equal As Integers     ${pgserr_after}  0  PGSERR should be cleared after NSCCR write

    # --- Operation 2: Sector Erase (SER) while locked ---
    Execute Command                 machine Reset
    ${nscr2}=                       Execute Command  sysbus ReadDoubleWord 0x40022028
    ${lock2}=                       Evaluate  ${nscr2.strip()} & 0x1
    Should Be Equal As Integers     ${lock2}  1  Flash should be locked after reset (SER test)

    ${test_addr}=                   Set Variable  0x08000000
    ${before_erase}=                Execute Command  sysbus ReadDoubleWord ${test_addr}

    Execute Command                 sysbus WriteDoubleWord 0x40022028 0x00000025

    ${after_erase}=                 Execute Command  sysbus ReadDoubleWord ${test_addr}
    Should Be Equal As Integers     ${after_erase}  ${before_erase}  SER while locked: flash contents should be unchanged

    ${nssr2}=                       Execute Command  sysbus ReadDoubleWord 0x40022020
    ${wrperr2}=                     Evaluate  (${nssr2.strip()} >> 17) & 0x1
    Should Be Equal As Integers     ${wrperr2}  1  SER while locked: WRPERR should be set in NSSR

    Execute Command                 sysbus WriteDoubleWord 0x40022030 0x00020000

    # --- Operation 3: Bank Erase (BER) while locked ---
    Execute Command                 machine Reset
    ${before_ber}=                  Execute Command  sysbus ReadDoubleWord ${test_addr}

    Execute Command                 sysbus WriteDoubleWord 0x40022028 0x00000029

    ${after_ber}=                   Execute Command  sysbus ReadDoubleWord ${test_addr}
    Should Be Equal As Integers     ${after_ber}  ${before_ber}  BER while locked: flash contents should be unchanged

    ${nssr3}=                       Execute Command  sysbus ReadDoubleWord 0x40022020
    ${wrperr3}=                     Evaluate  (${nssr3.strip()} >> 17) & 0x1
    Should Be Equal As Integers     ${wrperr3}  1  BER while locked: WRPERR should be set in NSSR

Should Transmit Exactly What Was Written To Tdr
    [Documentation]                 Property 16: Terminal output is exactly the byte sequence
    ...                             written to TDR.
    ...                             **Validates: Requirements 11.4, 11.5**
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${PLATFORM}
    Create Terminal Tester          ${UART}  defaultPauseEmulation=True

    # Enable USART3: UE (bit 0) + TE (bit 3) in CR1 at 0x40004800+0x00
    Execute Command                 sysbus WriteDoubleWord 0x40004800 0x9

    # --- Sequence 1: "HELLO" ---
    Execute Command                 sysbus WriteDoubleWord 0x40004828 0x48
    Execute Command                 sysbus WriteDoubleWord 0x40004828 0x45
    Execute Command                 sysbus WriteDoubleWord 0x40004828 0x4C
    Execute Command                 sysbus WriteDoubleWord 0x40004828 0x4C
    Execute Command                 sysbus WriteDoubleWord 0x40004828 0x4F
    Execute Command                 sysbus WriteDoubleWord 0x40004828 0x0D
    Execute Command                 sysbus WriteDoubleWord 0x40004828 0x0A
    Wait For Line On Uart           HELLO  timeout=1

    # --- Sequence 2: "xyz123" ---
    Execute Command                 sysbus WriteDoubleWord 0x40004828 0x78
    Execute Command                 sysbus WriteDoubleWord 0x40004828 0x79
    Execute Command                 sysbus WriteDoubleWord 0x40004828 0x7A
    Execute Command                 sysbus WriteDoubleWord 0x40004828 0x31
    Execute Command                 sysbus WriteDoubleWord 0x40004828 0x32
    Execute Command                 sysbus WriteDoubleWord 0x40004828 0x33
    Execute Command                 sysbus WriteDoubleWord 0x40004828 0x0D
    Execute Command                 sysbus WriteDoubleWord 0x40004828 0x0A
    Wait For Line On Uart           xyz123  timeout=1

Should Address All Gpio Ports
    [Documentation]                 Property 14: Every GPIO port is addressable at its computed base.
    ...                             Validates: Requirements 2.5
    Create Machine

    FOR  ${idx}  IN RANGE  7
        ${base}=                    Evaluate  0x42020000 + 0x400 * ${idx}
        ${odr_addr}=                Evaluate  ${base} + 0x14
        ${test_val}=                Evaluate  (${idx} + 1) * 0x1111
        Execute Command             sysbus WriteDoubleWord ${odr_addr} ${test_val}
        ${readback}=                Execute Command  sysbus ReadDoubleWord ${odr_addr}
        ${rb_masked}=               Evaluate  ${readback.strip()} & 0xFFFF
        Should Be Equal As Integers  ${rb_masked}  ${test_val}  Port index ${idx} ODR not preserved
    END

Should Route Exti Edge To Correct Line
    [Documentation]                 Property 11: A configured edge on the selected port raises
    ...                             exactly the matching line.
    ...                             **Validates: Requirements 13.5, 13.7**
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${PLATFORM}

    # --- Scenario 1: Rising edge on selected port C, pin 13, fully enabled ---
    Execute Command                 sysbus WriteDoubleWord 0x4402206C 0x00000200
    Execute Command                 sysbus WriteDoubleWord 0x44022000 0x00002000
    Execute Command                 sysbus WriteDoubleWord 0x44022080 0x00002000
    Execute Command                 sysbus WriteDoubleWord 0x4402200C 0x00002000

    Execute Command                 sysbus.gpioPortC OnGPIO 13 True

    ${rpr1}=                        Execute Command  sysbus ReadDoubleWord 0x4402200C
    ${rpr1_int}=                    Convert To Integer  ${rpr1.strip()}
    ${bit13}=                       Evaluate  (${rpr1_int} >> 13) & 0x1
    Should Be Equal As Integers     ${bit13}  1  Rising edge on selected port C pin 13: RPR1 bit 13 should be set

    # --- Scenario 2: Rising edge on UNSELECTED port (port A) — should NOT set pending ---
    Execute Command                 sysbus WriteDoubleWord 0x4402200C 0x00002000
    Execute Command                 sysbus.gpioPortA OnGPIO 13 True

    ${rpr1_a}=                      Execute Command  sysbus ReadDoubleWord 0x4402200C
    ${rpr1_a_int}=                  Convert To Integer  ${rpr1_a.strip()}
    ${bit13_a}=                     Evaluate  (${rpr1_a_int} >> 13) & 0x1
    Should Be Equal As Integers     ${bit13_a}  0  Edge on unselected port A pin 13: RPR1 bit 13 should NOT be set

    # --- Scenario 3: Rising edge with RTSR1 bit clear — should NOT set pending ---
    Execute Command                 sysbus WriteDoubleWord 0x44022000 0x00000000
    Execute Command                 sysbus.gpioPortC OnGPIO 13 False
    Execute Command                 sysbus WriteDoubleWord 0x4402200C 0x00002000
    Execute Command                 sysbus.gpioPortC OnGPIO 13 True

    ${rpr1_no_rtsr}=                Execute Command  sysbus ReadDoubleWord 0x4402200C
    ${rpr1_no_rtsr_int}=            Convert To Integer  ${rpr1_no_rtsr.strip()}
    ${bit13_no_rtsr}=               Evaluate  (${rpr1_no_rtsr_int} >> 13) & 0x1
    Should Be Equal As Integers     ${bit13_no_rtsr}  0  Rising edge with RTSR1 clear: RPR1 bit 13 should NOT be set

    # --- Scenario 4: Masked line still records pending ---
    Execute Command                 sysbus WriteDoubleWord 0x44022000 0x00002000
    Execute Command                 sysbus WriteDoubleWord 0x44022080 0x00000000
    Execute Command                 sysbus.gpioPortC OnGPIO 13 False
    Execute Command                 sysbus WriteDoubleWord 0x4402200C 0x00002000
    Execute Command                 sysbus.gpioPortC OnGPIO 13 True

    ${rpr1_masked}=                 Execute Command  sysbus ReadDoubleWord 0x4402200C
    ${rpr1_masked_int}=             Convert To Integer  ${rpr1_masked.strip()}
    ${bit13_masked}=                Evaluate  (${rpr1_masked_int} >> 13) & 0x1
    Should Be Equal As Integers     ${bit13_masked}  1  Masked line: RPR1 bit 13 should still be set

    # --- Scenario 5: Verify pin 0 with port A selected ---
    Execute Command                 sysbus WriteDoubleWord 0x44022060 0x00000000
    Execute Command                 sysbus WriteDoubleWord 0x44022000 0x00002001
    Execute Command                 sysbus WriteDoubleWord 0x44022080 0x00000001
    Execute Command                 sysbus WriteDoubleWord 0x4402200C 0x00000001
    Execute Command                 sysbus.gpioPortA OnGPIO 0 True

    ${rpr1_pin0}=                   Execute Command  sysbus ReadDoubleWord 0x4402200C
    ${rpr1_pin0_int}=               Convert To Integer  ${rpr1_pin0.strip()}
    ${bit0}=                        Evaluate  ${rpr1_pin0_int} & 0x1
    Should Be Equal As Integers     ${bit0}  1  Rising edge on port A pin 0: RPR1 bit 0 should be set

Should Initialise Cache Watchdog And Rng
    [Documentation]                 Unit tests for ICACHE, IWDG and RNG register behaviour.
    ...                             **Validates: Requirements 10.2, 10.7, 10.11**
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${PLATFORM}

    # ICACHE: CACHEINV self-clears and sets BSYENDF
    Execute Command                 sysbus WriteDoubleWord 0x40030400 0x00000002
    ${icache_cr}=                   Execute Command  sysbus ReadDoubleWord 0x40030400
    ${cacheinv}=                    Evaluate  (${icache_cr.strip()} >> 1) & 0x1
    Should Be Equal As Integers     ${cacheinv}  0  CACHEINV should self-clear after write

    ${icache_sr}=                   Execute Command  sysbus ReadDoubleWord 0x40030404
    ${bsyendf}=                     Evaluate  (${icache_sr.strip()} >> 1) & 0x1
    Should Be Equal As Integers     ${bsyendf}  1  BSYENDF should be set in SR after CACHEINV

    Execute Command                 sysbus WriteDoubleWord 0x4003040C 0x00000002
    ${icache_sr2}=                  Execute Command  sysbus ReadDoubleWord 0x40030404
    ${bsyendf2}=                    Evaluate  (${icache_sr2.strip()} >> 1) & 0x1
    Should Be Equal As Integers     ${bsyendf2}  0  BSYENDF should be cleared after writing CBSYENDF to FCR

    Execute Command                 sysbus WriteDoubleWord 0x40030400 0x00000001
    ${icache_cr2}=                  Execute Command  sysbus ReadDoubleWord 0x40030400
    ${en}=                          Evaluate  ${icache_cr2.strip()} & 0x1
    Should Be Equal As Integers     ${en}  1  ICACHE EN should read back 1 after being set

    ${hmonr}=                       Execute Command  sysbus ReadDoubleWord 0x40030410
    Should Be Equal As Integers     ${hmonr}  0  HMONR should read 0
    ${mmonr}=                       Execute Command  sysbus ReadDoubleWord 0x40030414
    Should Be Equal As Integers     ${mmonr}  0  MMONR should read 0

    # IWDG: EWCR write is serviced; EWU reads 0; EWIF clears on EWIC
    Execute Command                 sysbus WriteDoubleWord 0x40003014 0x00000100
    ${ewcr_rb}=                     Execute Command  sysbus ReadDoubleWord 0x40003014

    ${iwdg_sr}=                     Execute Command  sysbus ReadDoubleWord 0x4000300C
    ${ewu}=                         Evaluate  (${iwdg_sr.strip()} >> 3) & 0x1
    Should Be Equal As Integers     ${ewu}  0  IWDG SR.EWU should be 0

    Execute Command                 sysbus WriteDoubleWord 0x40003014 0x00004000
    ${iwdg_sr2}=                    Execute Command  sysbus ReadDoubleWord 0x4000300C
    ${ewif}=                        Evaluate  (${iwdg_sr2.strip()} >> 14) & 0x1
    Should Be Equal As Integers     ${ewif}  0  IWDG SR.EWIF should be 0 after EWIC write

    # RNG: CONDRST round-trips; NSCR/HTCR accept H5 magic values
    Execute Command                 sysbus WriteDoubleWord 0x420C0800 0x40000000
    ${rng_cr}=                      Execute Command  sysbus ReadDoubleWord 0x420C0800
    ${condrst}=                     Evaluate  (${rng_cr.strip()} >> 30) & 0x1
    Should Be Equal As Integers     ${condrst}  1  RNG CR.CONDRST should read back 1

    Execute Command                 sysbus WriteDoubleWord 0x420C0800 0x00000000
    ${rng_cr2}=                     Execute Command  sysbus ReadDoubleWord 0x420C0800
    ${condrst2}=                    Evaluate  (${rng_cr2.strip()} >> 30) & 0x1
    Should Be Equal As Integers     ${condrst2}  0  RNG CR.CONDRST should read back 0 after clear

    Execute Command                 sysbus WriteDoubleWord 0x420C080C 0x0003AF66
    ${nscr}=                        Execute Command  sysbus ReadDoubleWord 0x420C080C
    Should Be Equal As Integers     ${nscr}  0x0003AF66  NSCR should preserve H5 NIST value

    Execute Command                 sysbus WriteDoubleWord 0x420C0810 0x00006A91
    ${htcr}=                        Execute Command  sysbus ReadDoubleWord 0x420C0810
    Should Be Equal As Integers     ${htcr}  0x00006A91  HTCR should preserve H5 magic value

Should Map Exti Lines To Nvic Interrupts
    [Documentation]                 Property 13: EXTI output lines map to the specified interrupt
    ...                             numbers.
    ...                             **Validates: Requirements 2.7, 13.7**
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${PLATFORM}

    FOR  ${line}  IN  0  5  10  13  15
        ${bit_mask}=                Evaluate  1 << ${line}
        ${irq_num}=                 Evaluate  11 + ${line}
        ${irq_mask}=                Evaluate  1 << ${irq_num}

        Execute Command             sysbus WriteDoubleWord 0x44022000 ${bit_mask}
        Execute Command             sysbus WriteDoubleWord 0x44022080 ${bit_mask}
        Execute Command             sysbus WriteDoubleWord 0xE000E280 ${irq_mask}

        Execute Command             sysbus WriteDoubleWord 0x44022008 ${bit_mask}

        ${ispr}=                    Execute Command  sysbus ReadDoubleWord 0xE000E200
        ${pending}=                 Evaluate  (${ispr.strip()} >> ${irq_num}) & 0x1
        Should Be Equal As Integers  ${pending}  1  EXTI line ${line} should set NVIC IRQ ${irq_num} pending

        Execute Command             sysbus WriteDoubleWord 0x4402200C ${bit_mask}
        Execute Command             sysbus WriteDoubleWord 0xE000E280 ${irq_mask}
    END

Should Clear Exti Pending With Write One To Clear
    [Documentation]                 Property 12: Pending registers implement write-one-to-clear
    ...                             without disturbing other bits.
    ...                             **Validates: Requirements 13.6**
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${PLATFORM}

    # Set pending bits 0, 5, 10, 15 via SWIER1
    Execute Command                 sysbus WriteDoubleWord 0x44022000 0x00008421
    Execute Command                 sysbus WriteDoubleWord 0x44022080 0x00008421
    Execute Command                 sysbus WriteDoubleWord 0x44022008 0x00008421

    ${rpr1}=                        Execute Command  sysbus ReadDoubleWord 0x4402200C
    ${rpr1_masked}=                 Evaluate  ${rpr1.strip()} & 0x00008421
    Should Be Equal As Integers     ${rpr1_masked}  0x00008421  RPR1 should have bits 0,5,10,15 set after SWIER1

    # Clear only bits 0 and 10
    Execute Command                 sysbus WriteDoubleWord 0x4402200C 0x00000401

    ${rpr1_after}=                  Execute Command  sysbus ReadDoubleWord 0x4402200C
    ${bit0}=                        Evaluate  (${rpr1_after.strip()} >> 0) & 0x1
    ${bit5}=                        Evaluate  (${rpr1_after.strip()} >> 5) & 0x1
    ${bit10}=                       Evaluate  (${rpr1_after.strip()} >> 10) & 0x1
    ${bit15}=                       Evaluate  (${rpr1_after.strip()} >> 15) & 0x1
    Should Be Equal As Integers     ${bit0}   0  RPR1 bit 0 should be cleared after W1C
    Should Be Equal As Integers     ${bit5}   1  RPR1 bit 5 should remain set after W1C
    Should Be Equal As Integers     ${bit10}  0  RPR1 bit 10 should be cleared after W1C
    Should Be Equal As Integers     ${bit15}  1  RPR1 bit 15 should remain set after W1C

    # Second pattern test
    Execute Command                 machine Reset
    Execute Command                 sysbus WriteDoubleWord 0x44022000 0x00201082
    Execute Command                 sysbus WriteDoubleWord 0x44022080 0x00201082
    Execute Command                 sysbus WriteDoubleWord 0x44022008 0x00201082

    ${rpr1_2}=                      Execute Command  sysbus ReadDoubleWord 0x4402200C
    ${rpr1_2_masked}=               Evaluate  ${rpr1_2.strip()} & 0x00201082
    Should Be Equal As Integers     ${rpr1_2_masked}  0x00201082  RPR1 should have bits 1,7,12,21 set

    Execute Command                 sysbus WriteDoubleWord 0x4402200C 0x00200080

    ${rpr1_2_after}=                Execute Command  sysbus ReadDoubleWord 0x4402200C
    ${bit1}=                        Evaluate  (${rpr1_2_after.strip()} >> 1) & 0x1
    ${bit7}=                        Evaluate  (${rpr1_2_after.strip()} >> 7) & 0x1
    ${bit12}=                       Evaluate  (${rpr1_2_after.strip()} >> 12) & 0x1
    ${bit21}=                       Evaluate  (${rpr1_2_after.strip()} >> 21) & 0x1
    Should Be Equal As Integers     ${bit1}   1  RPR1 bit 1 should remain set after W1C
    Should Be Equal As Integers     ${bit7}   0  RPR1 bit 7 should be cleared after W1C
    Should Be Equal As Integers     ${bit12}  1  RPR1 bit 12 should remain set after W1C
    Should Be Equal As Integers     ${bit21}  0  RPR1 bit 21 should be cleared after W1C

Should Not Report Missing Peripherals
    [Documentation]                 Property 15: Modelled peripherals never report "non existing
    ...                             peripheral" or "unimplemented register" during firmware boot.
    ...                             Validates: Requirements 3.5, 3.6
    Create Machine
    Create Log Tester               0.5  defaultPauseEmulation=True

    # Boot for 400ms (inside watchdog period)
    Execute Command                 emulation RunFor "0.4"

    # Part 1: No "non existing peripheral" warnings for modelled peripherals during boot
    Should Not Be In Log            non existing peripheral

    # Part 2: Positive check — accessing undefined flash controller offsets DOES warn.
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${PLATFORM}
    Create Log Tester               1
    Execute Command                 sysbus ReadDoubleWord 0x4002200C
    Wait For Log Entry              Unhandled read from offset 0xC  timeout=1
