#ifndef BOOSTSYSTEM_H
#define BOOSTSYSTEM_H

#ifdef USE_BOOST

#include <vector>
#include <boost/numeric/odeint.hpp>


/*-----------------------------------------------------------------------------
 *  NOTICE:
 *  Before writing typedef for stepper read this 
 *  http://stackoverflow.com/questions/36564285/template-parameters-of-boostnumericodeintrunge-kutta-x-compatible-with-c/36564610?noredirect=1#comment60732822_36564610
 *-----------------------------------------------------------------------------*/
#ifdef USE_CUDA
typedef double value_type_;
typedef trust::device_vector< value_type_ > vector_type_;
typedef boost::numeric::odeint::runge_kutta_dopri5< 
        vector_type_
        , value_type_
        , vector_type_
        , value_type_
        , boost::numeric::odeint::thrust_algebra
        , boost::numeric::odeint::thrust_operations
    >  stepper_type_;
#else

typedef double value_type_;
typedef std::vector<value_type_> vector_type_;
//typedef boost::numeric::odeint::runge_kutta4< vector_type_ > rk4_stepper_type_;
//typedef boost::numeric::odeint::runge_kutta_dopri5< vector_type_ > rk_dopri_stepper_type_;


/*-----------------------------------------------------------------------------
 *  This stepper type found to be most suitable for adaptive solver. The gsl
 *  implementation has runge_kutta_fehlberg78 solver.
 *-----------------------------------------------------------------------------*/
typedef boost::numeric::odeint::runge_kutta_cash_karp54< vector_type_ > rk_karp_stepper_type_;

//typedef boost::numeric::odeint::runge_kutta_fehlberg78< vector_type_ > rk_felhberg_stepper_type_;

#endif

/*
 * =====================================================================================
 *        Class:  BoostSys
 *  Description:  The ode system of ksolve. It uses boost library to solve it.
 *  It is intended to be gsl replacement.
 * =====================================================================================
 */
class BoostSys
{
    public:
        BoostSys (); 
        ~BoostSys();

        /* Pointer to the arbitrary parameters of the system */
        void * params;
};

#endif // USE_BOOST

#endif /* end of include guard: BOOSTSYSTEM_H */

