base components:

- transistor (pwr, cond) => (cond ? 0 : pwr)

optimized components:

- and(2), or(2), nor(2), xor(2), add(1,1,1,1), add(2,2,2,1), add(4, 4, 4, 1), ...

components have designated inputs and outputs. when there are subcomponents, the 'call' instruction is used to call a subcomponent


still needed for optimization:

- should we go back to front instead of front to back? that way we can ignore unused things?
- either way we need to be able to skip simulating unneeded things

do we want?

- do we want to disallow making something from nothing?
- if we do this, then 'energy usage' metric makes sense



histograms:

- cycle time (worst-case distance from input to output)
- area
- energy usage (number of on state wires cells each frame)
  - alternatively: each component which has any inputs on uses energy based on its area
  - to reduce energy usage, make sure components have all their inputs off
  - this matches up with real cpu usage so maybe this makes more sense





levels:
0-0 not (built-in gate)
0-1 or (connect wires together)
0-2 nor (not or)
0-9 and (not (not a or not b))




game:

- square
- touching wires connect


interface:

| . | . |
|-|-|
|EDITOR(90%)|Component Name,Component Browser|
|play/stop/Test Cases|Stats(cycle time,area,energy usage)|


structure:

- A component is a grid with components. Components are all rectangular.
  - Components have 1 square padding around the edge. In the padding square, you mark the inputs and outputs.
  - You can click an input to toggle its previewed value.
- The basic wire component is 1x1. There are sized wire components for 2x2, 4x4, 8x8, 16x16, ...
- To compile a component:
  - The component grid is converted to a component graph
    - Cyclic graphs will error here, and the associated wires can be rendered in an error state
  - The component graph is rendered to component bytecode
    - When it's the main component, wire states cannot be reused because they are needed for rendering.
    - When it is a sub-component, wire states can be reused. The graph should be able to identify lots of opportunities for this.
- The scene is converted to bytecode for faster execution
- It should be pretty simple to jit-compile the bytecode into simple CPU instructions for even more performance.
  - Just basic translation, no register allocation or anything. It should speed up execution, but by how much? And it will need to be implemented for both x86_64 and aarch64.

size:

- a wire is a bit less than 1x1, it connects to anything touching it
- a 2x wire is 2x2. a 4x wire is 4x4
- that means 4x wires take up less space than 4x 1 wires - that would take 7 tiles
  - this is good because 4x wires use less cpu than 4 1x wires, so we want to encourage them
  - also it is a counterbalance because 2x wires are scale=2 which means they can't be placed in as many places as 1x wires
- the splitter to split a 4x wire into a 1x wire is 7 tall

do we do wire width?
- seems complicated idk
- the point of this is to make energy usage more meaningful
