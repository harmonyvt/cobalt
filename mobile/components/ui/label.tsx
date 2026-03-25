import { Pressable, View } from 'react-native';

import { Text } from '@/components/ui/text';
import { cn } from '@/lib/utils';

type LabelProps = React.ComponentProps<typeof Text> & {
  className?: string;
  disabled?: boolean;
};

function Label({ className, disabled, onPress, ...props }: LabelProps) {
  return (
    <Pressable disabled={!onPress || disabled} onPress={onPress}>
      <View className={cn(disabled && 'opacity-50')}>
        <Text className={cn('text-sm font-medium text-foreground', className)} {...props} />
      </View>
    </Pressable>
  );
}

export { Label };
