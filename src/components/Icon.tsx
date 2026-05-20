/**
 * Single source of truth for global UI icons.
 *
 * Backed by unplugin-icons + @iconify-json/ph (Phosphor regular). Each
 * imported icon becomes its own Preact component compiled at build time —
 * no runtime fetch, only used icons enter the bundle.
 *
 * Add a new icon: pick from https://phosphoricons.com, then add one
 * `import ... from '~icons/ph/<name>'` line and a case below.
 */
import PhPlus from '~icons/ph/plus';
import PhX from '~icons/ph/x';
import PhGear from '~icons/ph/gear';
import PhTrash from '~icons/ph/trash';
import PhDotsThree from '~icons/ph/dots-three';
import PhPencil from '~icons/ph/pencil';
import PhCaretLeft from '~icons/ph/caret-left';
import PhCaretRight from '~icons/ph/caret-right';
import PhPushPin from '~icons/ph/push-pin';
import PhPushPinFill from '~icons/ph/push-pin-fill';
import PhMagnifyingGlass from '~icons/ph/magnifying-glass';
import PhFunnel from '~icons/ph/funnel';
import PhListBullets from '~icons/ph/list-bullets';
import PhInfo from '~icons/ph/info';
import PhChartBar from '~icons/ph/chart-bar';

export type IconName =
  | 'plus'
  | 'x'
  | 'gear'
  | 'trash'
  | 'dots-three'
  | 'pencil'
  | 'caret-left'
  | 'caret-right'
  | 'pin'
  | 'pin-fill'
  | 'magnifying-glass'
  | 'funnel'
  | 'list-bullets'
  | 'info'
  | 'chart-bar';

const COMPONENT: Record<IconName, typeof PhPlus> = {
  plus: PhPlus,
  x: PhX,
  gear: PhGear,
  trash: PhTrash,
  'dots-three': PhDotsThree,
  pencil: PhPencil,
  'caret-left': PhCaretLeft,
  'caret-right': PhCaretRight,
  pin: PhPushPin,
  'pin-fill': PhPushPinFill,
  'magnifying-glass': PhMagnifyingGlass,
  funnel: PhFunnel,
  'list-bullets': PhListBullets,
  info: PhInfo,
  'chart-bar': PhChartBar,
};

interface Props {
  name: IconName;
  /** Width/height in px. Defaults to 14. */
  size?: number;
  /** Pass-through class for color / margin / etc. (Use text-* for color.) */
  class?: string;
  title?: string;
}

export function Icon({ name, size = 14, class: className, title }: Props) {
  const C = COMPONENT[name];
  return <C width={size} height={size} class={className} aria-label={title} aria-hidden={title ? undefined : true} />;
}
