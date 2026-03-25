import { Pressable, View } from 'react-native';

import { cn } from '@/lib/utils';

type SwitchProps = {
  checked: boolean;
  className?: string;
  disabled?: boolean;
  onCheckedChange?: (checked: boolean) => void;
};

function Switch({ checked, className, disabled, onCheckedChange }: SwitchProps) {
  return (
    <Pressable
      className={cn(
        'flex h-[1.15rem] w-8 shrink-0 flex-row items-center rounded-full border border-transparent shadow-sm shadow-black/5',
        checked ? 'bg-primary' : 'bg-input dark:bg-input/80',
        disabled && 'opacity-50',
        className
      )}
      disabled={disabled}
      onPress={() => onCheckedChange?.(!checked)}>
      <View
        className={cn(
          'size-4 rounded-full bg-background transition-transform',
          checked
            ? 'translate-x-3.5 dark:bg-primary-foreground'
            : 'translate-x-0 dark:bg-foreground'
        )}
      />
    </Pressable>
  );
}

export { Switch };
