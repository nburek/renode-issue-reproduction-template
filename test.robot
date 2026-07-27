*** Variables ***
${SCRIPT}                     ${CURDIR}/test.resc
${UART}                       sysbus.usart3

*** Keywords ***
Load Script
    Execute Script            ${SCRIPT}
    Create Terminal Tester    ${UART}

*** Test Cases ***
Should Print Boot Banner
    [Documentation]    Bare-metal STM32H563 firmware boots and prints its banner.
    ...                This test PASSES with the STM32H5 peripheral models from
    ...                nburek/renode-infrastructure@915-stm32h563_support.
    ...                Fix for: github.com/renode/renode/issues/915
    Load Script
    Start Emulation

    Wait For Line On Uart     Welcome to STM32 world !    timeout=5
