function predictedStateDistr = genKFprediction(priorStateDistr,nextStateGivenCurrDistr)
%Prediction step update of numerical kalman filter.
%Implements: p(x_{k+1}|)=\int p(x_{k+1}|x_k)p(x_k) dx_k
%INPUT
%nextStateGivenCurrDistr: p(x_{k+1}|x_k) [TRANSITION MATRIX]
%priorStateDistr: p(x_k) [PRIOR STATE ESTIMATE], column vector
%OUTPUT:
%predictedStateDistr: p(x_{k+1}) [PREDICTED STATE], column vector

predictedStateDistr=nextStateGivenCurrDistr * priorStateDistr;
predictedStateDistr=normalize(predictedStateDistr);
end

function p=normalize(p)
s=sum(p(:));
if s==0
    error('P sums to 0')
else
    p=p/s;
end
end
