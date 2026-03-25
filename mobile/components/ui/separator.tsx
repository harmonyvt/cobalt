import { View } from 'react-native';

import { cn } from '@/lib/utils';

type SeparatorProps = {
  className?: string;
  orientation?: 'horizontal' | 'vertical';
};

function Separator({ className, orientation = 'horizontal' }: SeparatorProps) {
  return (
    <View
      className={cn(
        'shrink-0 bg-border',
        orientation === 'horizontal' ? 'h-px w-full' : 'h-full w-px',
        className
      )}
    />
  );
}

export { Separator };
