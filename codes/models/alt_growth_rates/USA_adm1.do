// USA | adm1

clear all
//-----------------------setup

// import end of sample cut-off 
import delim using codes/data/cutoff_dates.csv, clear 
keep if tag == "default"
local end_sample = end_date[1]

// load data
insheet using data/processed/adm1/USA_processed.csv, clear 

cap set scheme covid19_fig3 // optional scheme for graphs

// set up time variables
gen t = date(date, "YMD",2020)
lab var t "date"
gen dow = dow(t)
gen month = month(t)
gen year = year(t)
gen day = day(t)

//clean up
drop if t < mdy(3,3,2020) // begin sample on March 3, 2020
keep if t <= date("`end_sample'","YMD") // to match other country end dates

encode adm1, gen(adm1_id)
duplicates report adm1_id t

//set up panel
tsset adm1_id t, daily

//quality control
drop if cum_confirmed_cases < 10 

// very short panel of data
bysort adm1_id: egen total_obs = total((adm1_id~=.))
drop if total_obs < 4 // drop state if less than 4 obs

// flag which admin unit has longest series
tab adm1_name if cum_confirmed_cases!=., sort 
bysort adm1_name: egen adm1_obs_ct = count(cum_confirmed_cases)

// if multiple admin units have max number of days w/ confirmed cases, 
// choose the admin unit with the max number of confirmed cases 
bysort adm1_name: egen adm1_max_cases = max(cum_confirmed_cases)
egen max_obs_ct = max(adm1_obs_ct)
bysort adm1_obs_ct: egen max_obs_ct_max_cases = max(adm1_max_cases) 

gen longest_series = adm1_obs_ct==max_obs_ct & adm1_max_cases==max_obs_ct_max_cases
drop adm1_obs_ct adm1_max_cases max_obs_ct max_obs_ct_max_cases

sort adm1_id t
tab adm1_name if longest_series==1 & cum_confirmed_cases!=.

//construct dep vars
lab var cum_confirmed_cases "cumulative confirmed cases"

gen l_cum_confirmed_cases = log(cum_confirmed_cases)
lab var l_cum_confirmed_cases "log(cum_confirmed_cases)"

gen D_l_cum_confirmed_cases = D.l_cum_confirmed_cases 
lab var D_l_cum_confirmed_cases "change in log(cum_confirmed_cases)"

//quality control
replace D_l_cum_confirmed_cases = . if D_l_cum_confirmed_cases < 0 // cannot have negative changes in cumulative values

//--------------testing regime changes

// some testing regime changes at the state-level
*tab adm1_name t if testing_regime>0

// grab each date of any testing regime change by state
preserve
	collapse (min) t, by(testing_regime adm1_name)
	sort adm1_name t //should already be sorted but just in case
	by adm1_name: drop if _n==1 //dropping 1st testing regime of state sample (no change to control for)
	levelsof t, local(testing_change_dates)
restore

// create a dummy for each testing regime change date w/in state
foreach t_chg of local testing_change_dates{
	local t_str = string(`t_chg', "%td")
	gen testing_regime_change_`t_str' = t==`t_chg' * D.testing_regime
}

//------------------diagnostic

// diagnostic plot of trends with sample avg as line
reg D_l_cum_confirmed_cases
gen sample_avg = _b[_cons]
replace sample_avg = . if longest_series==0 & e(sample) == 1

reg D_l_cum_confirmed_cases i.t
predict day_avg if longest_series==1 & e(sample) == 1

lab var day_avg "Observed avg. change in log cases"

tw (sc D_l_cum_confirmed_cases t, msize(tiny))(line sample_avg t)(sc day_avg t)


//------------------grouping treatments (based on timing and similarity)

//paid_sick_leave_popw // not enough follow up data
//work_from_home_popw // not enough follow up data

capture: drop p_*
gen p_1 = (home_isolation_popw+ no_gathering_popw + social_distance_popw +.5*social_distance_opt_popwt) /3.5
gen p_2 = (school_closure_popw + .5*school_closure_opt_popwt)/1.5
gen p_3 = (travel_ban_local_popw + business_closure_popw )/2

//gen p_3 = (work_from_home_opt_popwt + social_distance_opt_popwt + school_closure_opt_popwt + business_closure_opt_popwt + home_isolation_opt_popwt + paid_sick_leave_opt_popwt)/6

lab var p_1 "social distancing"
lab var p_2 "close schools"
lab var p_3 "close business + travel ban"


//------------------main estimates

// output data used for reg
outsheet using "models/reg_data/USA_reg_data.csv", comma replace

// main regression model
reghdfe D_l_cum_confirmed_cases p_* testing_regime_change_*, absorb(i.adm1_id i.dow, savefe) cluster(t) resid

outreg2 using "results/tables/USA_estimates_table", word replace label ///
 addtext(State FE, "YES", Day-of-Week FE, "YES") title("Regression output: United States")
cap erase "results/tables/USA_estimates_table.txt"


// export coef
tempfile results_file
postfile results str18 adm0 str18 policy beta se using `results_file', replace
foreach var in "p_1" "p_2" "p_3" {
	post results ("USA") ("`var'") (round(_b[`var'], 0.001)) (round(_se[`var'], 0.001)) 
}

// effect of package of policies (FOR FIG2)
lincom p_1 + p_2 + p_3 
post results ("USA") ("comb. policy") (round(r(estimate), 0.001)) (round(r(se), 0.001)) 


//looking at different policies (similar to Fig2)
coefplot, keep(p_*)


//------------- checking error structure (merge these graphs for APPENDIX FIGURE)

predict e if e(sample), resid

hist e, bin(30) tit("United States") lcolor(white) fcolor(navy) xsize(5) name(hist_usa, replace)

qnorm e, mcolor(black) rlopts(lcolor(black)) xsize(5) name(qn_usa, replace)

graph combine hist_usa qn_usa, rows(1) xsize(10) saving(results/figures/appendix/error_dist/error_usa.gph, replace)
graph drop hist_usa qn_usa


// ------------- generating predicted values and counterfactual predictions based on treatment

// predicted "actual" outcomes with real policies
*predict y_actual if e(sample)
predictnl y_actual = xb() + __hdfe1__ + __hdfe2__ if e(sample), ci(lb_y_actual ub_y_actual)

lab var y_actual "predicted growth with actual policy"

// estimating magnitude of treatment effects for each obs
gen treatment = ///
p_1 * _b[p_1] + ///
p_2 * _b[p_2] + ///
p_3 * _b[p_3] /// 
if e(sample)

// predicting counterfactual growth for each obs
*gen y_counter = y_actual - treatment if e(sample)
predictnl y_counter = ///
testing_regime_change_13mar2020 * _b[testing_regime_change_13mar2020] + ///
testing_regime_change_16mar2020 * _b[testing_regime_change_16mar2020] + ///
testing_regime_change_18mar2020 * _b[testing_regime_change_18mar2020] + /// 
_b[_cons] + __hdfe1__ + __hdfe2__ if e(sample), ci(lb_counter ub_counter)

// compute ATE
preserve
	keep if e(sample) == 1
	collapse  D_l_cum_confirmed_cases p_* 
	predictnl ATE = p_1*_b[p_1] + p_2* _b[p_2] + p_3*_b[p_3], ci(LB UB) se(sd) p(pval)
	g adm0 = "USA"
	outsheet * using "models/USA_ATE.csv", comma replace 
restore

//quality control: cannot have negative growth in cumulative cases
// fix so there are no negative growth rates in error bars
foreach var of varlist y_actual y_counter lb_y_actual ub_y_actual lb_counter ub_counter{
	replace `var' = 0 if `var'<0 & `var'!=.
}

// the mean here is the avg "biological" rate of initial spread (FOR Fig2)
sum y_counter
post results ("USA") ("no_policy rate") (round(r(mean), 0.001)) (round(r(sd), 0.001)) 

//export predicted counterfactual growth rate
preserve
	keep if e(sample) == 1
	keep y_counter
	g adm0 = "USA"
	outsheet * using "models/USA_preds.csv", comma replace
restore

// the mean average growth rate suppression delivered by existing policy (FOR TEXT)
sum treatment


// computing daily avgs in sample, store with a single panel unit (longest time series)
reg y_actual i.t
predict m_y_actual if longest_series==1

reg y_counter i.t
predict m_y_counter if longest_series==1


// add random noise to time var to create jittered error bars
set seed 1234
g t_random = t + rnormal(0,1)/10
g t_random2 = t + rnormal(0,1)/10

// Graph of predicted growth rates (FOR FIG3)
// fixed x-axis across countries
tw (rspike ub_y_actual lb_y_actual t_random,  lwidth(vthin) color(blue*.5)) ///
(rspike ub_counter lb_counter t_random2, lwidth(vthin) color(red*.5)) ///
|| (scatter y_actual t_random,  msize(tiny) color(blue*.5) ) ///
(scatter y_counter t_random2, msize(tiny) color(red*.5)) ///
(connect m_y_actual t, color(blue) m(square) lpattern(solid)) ///
(connect m_y_counter t, color(red) lpattern(dash) m(Oh)) ///
(sc day_avg t, color(black)) ///
if e(sample), ///
title("United States", ring(0)) ytit("Growth rate of" "cumulative cases" "({&Delta}log per day)") ///
xscale(range(21930(10)21999)) xlabel(21930(10)21999, format(%tdMon_DD) tlwidth(medthick)) tmtick(##10) ///
yscale(r(0(.2).8)) ylabel(0(.2).8) plotregion(m(b=0)) ///
saving(results/figures/fig3/raw/USA_adm1_conf_cases_growth_rates_fixedx.gph, replace)


//-------------------------------Running the model for certain states

foreach state in "Washington" "California" "New York" {

	reghdfe D_l_cum_confirmed_cases p_* testing_regime_change_* if adm1_name=="`state'", noabsorb
	
	local state0 = regexr("`state'", " ", "")
	local rowname = "USA_" + "`state0'"
	display "`rowname'"
	post results ("`rowname'") ("no_policy rate") (round(_b[_cons], 0.001)) (round(_se[_cons], 0.001)) 

	// predicted "actual" outcomes with real policies
	predictnl y_actual_`state0' = xb() if e(sample), ///
	ci(lb_y_actual_`state0' ub_y_actual_`state0')
		
	// predicting counterfactual growth for each obs
	predictnl y_counter_`state0' = ///
	testing_regime_change_13mar2020 * _b[testing_regime_change_13mar2020] + ///
	testing_regime_change_16mar2020 * _b[testing_regime_change_16mar2020] + ///
	testing_regime_change_18mar2020 * _b[testing_regime_change_18mar2020] + /// 
	_b[_cons] if e(sample), ///
	ci(lb_counter_`state0' ub_counter_`state0')

	// quality control: don't want to be forecasting negative growth (not modeling recoveries)
	// fix so there are no negative growth rates in error bars
	foreach var of varlist y_actual_`state0' y_counter_`state0' lb_y_actual_`state0' ub_y_actual_`state0' lb_counter_`state0' ub_counter_`state0' {
		replace `var' = 0 if `var'<0 & `var'!=.
	}

	// Observed avg change in log cases
	reg D_l_cum_confirmed_cases i.t if adm1_name=="`state'"
	predict day_avg_`state0' if adm1_name=="`state'" & e(sample) == 1
	
	// Graph of predicted growth rates
	// fixed x-axis across countries
	local title = "`state'" + " State, USA"
	
	tw (rspike ub_y_actual_`state0' lb_y_actual_`state0' t,  lwidth(vthin) color(blue*.5)) ///
	(rspike ub_counter_`state0' lb_counter_`state0' t, lwidth(vthin) color(red*.5)) ///
	|| (scatter y_actual_`state0' t,  msize(tiny) color(blue*.5) ) ///
	(scatter y_counter_`state0' t, msize(tiny) color(red*.5)) ///
	(connect y_actual_`state0' t, color(blue) m(square) lpattern(solid)) ///
	(connect y_counter_`state0' t, color(red) lpattern(dash) m(Oh)) ///
	(sc day_avg_`state0' t, color(black)) ///
	if e(sample), ///
	title("`title'", ring(0)) ytit("Growth rate of" "cumulative cases" "({&Delta}log per day)") xtit("") ///
	xscale(range(21930(10)21999)) xlabel(21930(10)21999, nolabels tlwidth(medthick)) tmtick(##10) ///
	yscale(r(0(.2).8)) ylabel(0(.2).8) plotregion(m(b=0)) ///
	saving(results/figures/appendix/sub_natl_growth_rates/`state0'_conf_cases_growth_rates_fixedx.gph, replace)
}

postclose results

preserve
	use `results_file', clear
	outsheet * using "models/USA_coefs.csv", comma replace
restore
