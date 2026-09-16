// Termux's Node reports process.platform === 'android'; Playwright only knows
// darwin/linux/win32 and throws at module-init. We supply executablePath ourselves,
// so presenting as linux is accurate for every path Playwright then takes.
Object.defineProperty(process, 'platform', { value: 'linux', configurable: true });
