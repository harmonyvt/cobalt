import { DarkTheme, DefaultTheme, type Theme } from '@react-navigation/native';

export const THEME = {
  light: {
    background: 'hsl(33 33% 97%)',
    foreground: 'hsl(210 20% 11%)',
    card: 'hsl(34 43% 99%)',
    cardForeground: 'hsl(210 20% 11%)',
    popover: 'hsl(34 43% 99%)',
    popoverForeground: 'hsl(210 20% 11%)',
    primary: 'hsl(212 55% 17%)',
    primaryForeground: 'hsl(41 90% 96%)',
    secondary: 'hsl(38 35% 92%)',
    secondaryForeground: 'hsl(212 45% 18%)',
    muted: 'hsl(36 20% 89%)',
    mutedForeground: 'hsl(210 10% 36%)',
    accent: 'hsl(21 84% 59%)',
    accentForeground: 'hsl(33 100% 98%)',
    destructive: 'hsl(0 78% 58%)',
    destructiveForeground: 'hsl(33 100% 98%)',
    border: 'hsl(35 24% 83%)',
    input: 'hsl(35 24% 83%)',
    ring: 'hsl(21 84% 59%)',
    radius: '0.875rem',
  },
  dark: {
    background: 'hsl(218 33% 10%)',
    foreground: 'hsl(38 47% 94%)',
    card: 'hsl(217 30% 13%)',
    cardForeground: 'hsl(38 47% 94%)',
    popover: 'hsl(217 30% 13%)',
    popoverForeground: 'hsl(38 47% 94%)',
    primary: 'hsl(36 92% 70%)',
    primaryForeground: 'hsl(216 48% 12%)',
    secondary: 'hsl(214 19% 20%)',
    secondaryForeground: 'hsl(38 47% 94%)',
    muted: 'hsl(214 19% 20%)',
    mutedForeground: 'hsl(35 16% 73%)',
    accent: 'hsl(23 88% 63%)',
    accentForeground: 'hsl(216 48% 12%)',
    destructive: 'hsl(0 70% 59%)',
    destructiveForeground: 'hsl(38 47% 94%)',
    border: 'hsl(214 19% 24%)',
    input: 'hsl(214 19% 24%)',
    ring: 'hsl(23 88% 63%)',
    radius: '0.875rem',
  },
} as const;

const toCssVarValue = (value: string) => {
  if (value.startsWith('hsl(') && value.endsWith(')')) {
    return value.slice(4, -1);
  }

  return value;
};

export const THEME_VARS: Record<'light' | 'dark', Record<string, string>> = {
  light: {
    '--background': toCssVarValue(THEME.light.background),
    '--foreground': toCssVarValue(THEME.light.foreground),
    '--card': toCssVarValue(THEME.light.card),
    '--card-foreground': toCssVarValue(THEME.light.cardForeground),
    '--popover': toCssVarValue(THEME.light.popover),
    '--popover-foreground': toCssVarValue(THEME.light.popoverForeground),
    '--primary': toCssVarValue(THEME.light.primary),
    '--primary-foreground': toCssVarValue(THEME.light.primaryForeground),
    '--secondary': toCssVarValue(THEME.light.secondary),
    '--secondary-foreground': toCssVarValue(THEME.light.secondaryForeground),
    '--muted': toCssVarValue(THEME.light.muted),
    '--muted-foreground': toCssVarValue(THEME.light.mutedForeground),
    '--accent': toCssVarValue(THEME.light.accent),
    '--accent-foreground': toCssVarValue(THEME.light.accentForeground),
    '--destructive': toCssVarValue(THEME.light.destructive),
    '--destructive-foreground': toCssVarValue(THEME.light.destructiveForeground),
    '--border': toCssVarValue(THEME.light.border),
    '--input': toCssVarValue(THEME.light.input),
    '--ring': toCssVarValue(THEME.light.ring),
    '--radius': toCssVarValue(THEME.light.radius),
  },
  dark: {
    '--background': toCssVarValue(THEME.dark.background),
    '--foreground': toCssVarValue(THEME.dark.foreground),
    '--card': toCssVarValue(THEME.dark.card),
    '--card-foreground': toCssVarValue(THEME.dark.cardForeground),
    '--popover': toCssVarValue(THEME.dark.popover),
    '--popover-foreground': toCssVarValue(THEME.dark.popoverForeground),
    '--primary': toCssVarValue(THEME.dark.primary),
    '--primary-foreground': toCssVarValue(THEME.dark.primaryForeground),
    '--secondary': toCssVarValue(THEME.dark.secondary),
    '--secondary-foreground': toCssVarValue(THEME.dark.secondaryForeground),
    '--muted': toCssVarValue(THEME.dark.muted),
    '--muted-foreground': toCssVarValue(THEME.dark.mutedForeground),
    '--accent': toCssVarValue(THEME.dark.accent),
    '--accent-foreground': toCssVarValue(THEME.dark.accentForeground),
    '--destructive': toCssVarValue(THEME.dark.destructive),
    '--destructive-foreground': toCssVarValue(THEME.dark.destructiveForeground),
    '--border': toCssVarValue(THEME.dark.border),
    '--input': toCssVarValue(THEME.dark.input),
    '--ring': toCssVarValue(THEME.dark.ring),
    '--radius': toCssVarValue(THEME.dark.radius),
  },
};

export const NAV_THEME: Record<'light' | 'dark', Theme> = {
  light: {
    ...DefaultTheme,
    colors: {
      ...DefaultTheme.colors,
      background: THEME.light.background,
      border: THEME.light.border,
      card: THEME.light.card,
      notification: THEME.light.destructive,
      primary: THEME.light.primary,
      text: THEME.light.foreground,
    },
  },
  dark: {
    ...DarkTheme,
    colors: {
      ...DarkTheme.colors,
      background: THEME.dark.background,
      border: THEME.dark.border,
      card: THEME.dark.card,
      notification: THEME.dark.destructive,
      primary: THEME.dark.primary,
      text: THEME.dark.foreground,
    },
  },
};
