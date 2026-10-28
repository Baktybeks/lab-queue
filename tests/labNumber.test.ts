import {test} from 'node:test';
import assert from 'node:assert/strict';
import {labNumber} from '../src/features/set-active-lab/lib/labNumber.ts';
test('Active lab accepts leading zeros and rejects empty, fractional and out-of-range values',()=>{
  for(const text of ['7','07','007',' 7 '])assert.equal(labNumber(text),7);
  assert.equal(labNumber('1'),1);assert.equal(labNumber('99'),99);
  for(const text of ['',' ','0','00','100','-1','1.5','abc'])assert.equal(labNumber(text),null);
});
