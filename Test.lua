eps = 1e-3

function testJacobian(module, input, x, dx)
   module:forward(input)

   x = x or input

   local sx = torch.CudaTensor(x:storage())
   local gradInput = ct.emptyAs(module.output)
   local sgradInput = torch.CudaTensor(gradInput:storage())
   local jacobian = torch.Tensor(sx:nElement(), gradInput:nElement())
   local jacobian_hat = torch.Tensor(sx:nElement(), gradInput:nElement())

   -- Build Jacobian from module's updateGradInput
   sgradInput:zero()
   for i = 1,gradInput:nElement() do
      sgradInput[i] = 1
      module:updateGradInput(input, gradInput)
      if dx then
         dx:zero()
         module:accGradParameters(input, gradInput)
         jacobian:select(2, i):copy(dx)
      else
         jacobian:select(2, i):copy(module.gradInput:t())
      end
      sgradInput[i] = 0
   end

   -- Numerically estimate the Jacobian
   for i = 1,sx:nElement() do
      orig = sx[i]
      sx[i] = orig + eps
      module:forward(input)
      local f1 = module.output:clone()

      sx[i] = orig - eps
      module:forward(input)
      local f2 = module.output:clone()

      jacobian_hat:select(1, i):copy(f1:add(-1, f2):div(2 * eps):t())
      sx[i] = orig
   end

   return jacobian:add(-1, jacobian_hat):abs():max()
end

function testJacobianParameters(module, input)
   x, dx = module:getParameters()
   return testJacobian(module, input, x, dx)
end

function testCriterion(module, input, target)
   module:forward(input, target)
   module:backward(input, target)

   local sinput = torch.CudaTensor(input:storage())
   local grad_hat = torch.Tensor(sinput:nElement())
   for i = 1,sinput:nElement() do
      orig = sinput[i]
      sinput[i] = orig + eps
      local f1 = module:forward(input, target)

      sinput[i] = orig - eps
      local f2 = module:forward(input, target)

      grad_hat[i] = (f1 - f2) / (2 * eps)
      sinput[i] = orig
   end

   return module.gradInput:t():double():add(-1, grad_hat):abs():max()
end
