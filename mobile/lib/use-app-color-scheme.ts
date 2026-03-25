import { useEffect } from 'react';
import { useColorScheme } from 'nativewind';

export function useAppColorScheme() {
  const { colorScheme, setColorScheme } = useColorScheme();
  const resolvedColorScheme: 'light' | 'dark' = colorScheme === 'dark' ? 'dark' : 'light';

  useEffect(() => {
    setColorScheme('system');
  }, [setColorScheme]);

  return {
    colorScheme: resolvedColorScheme,
    isDarkColorScheme: resolvedColorScheme === 'dark',
  };
}
