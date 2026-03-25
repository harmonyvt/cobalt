import { useColorScheme } from 'react-native';

export function useAppColorScheme() {
  const system = useColorScheme();
  const colorScheme: 'light' | 'dark' = system === 'dark' ? 'dark' : 'light';

  return {
    colorScheme,
    isDarkColorScheme: colorScheme === 'dark',
  };
}
