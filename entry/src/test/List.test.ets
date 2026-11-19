import localUnitTest from './LocalUnit.test';
import a3RouterTest from './A3Router.test';
import a3StatsTest from './A3Stats.test';

export default function testsuite() {
  localUnitTest();
  a3RouterTest();
  a3StatsTest();
}